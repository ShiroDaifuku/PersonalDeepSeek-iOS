import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

@MainActor
final class MemoryStoreTests: XCTestCase {
    func testProfilePayloadRoundTripsEmptyAndPopulatedData() throws {
        let values: [UserMemoryProfilePayload] = [
            .empty,
            .init(
                durable: ["durable"],
                preferences: ["preference"],
                ongoing: ["ongoing"],
                recentState: ["state"],
                recentFocus: ["focus"]
            )
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(UserMemoryProfilePayload.self, from: data), value)
            XCTAssertEqual(value.schemaVersion, UserMemoryProfilePayload.currentSchemaVersion)
        }
    }

    func testCompletedTurnFingerprintIsStableAndIdentifierBased() {
        let conversationID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let userID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let assistantID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let first = CompletedTurnFingerprint.make(conversationID: conversationID, userMessageID: userID, assistantMessageID: assistantID)
        let second = CompletedTurnFingerprint.make(conversationID: conversationID, userMessageID: userID, assistantMessageID: assistantID)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, CompletedTurnFingerprint.make(conversationID: conversationID, userMessageID: userID, assistantMessageID: UUID()))
    }

    func testProfileCreateUpdateAndPersistentReload() async throws {
        let location = try temporaryStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        try await writeProfile(to: location.store)
        let reloaded = try await readProfile(from: location.store)
        XCTAssertEqual(reloaded.scopeID, MemoryScope.localDefault)
        XCTAssertEqual(reloaded.revision, 1)
        XCTAssertEqual(reloaded.payload.preferences, ["prefers concise answers"])
        XCTAssertEqual(reloaded.payload.recentFocus, ["memory design"])
    }

    func testEmptyProfilePersistsAcrossContainerReload() async throws {
        let location = try temporaryStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let created = try await writeEmptyProfile(to: location.store)
        XCTAssertEqual(created.payload, .empty)
        XCTAssertEqual(created.revision, 0)

        let secondContainer = try makeFullContainer(at: location.store)
        let secondStore = MemoryStore(modelContainer: secondContainer)
        let reloaded = try await secondStore.profile(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(reloaded?.payload, .empty)
        XCTAssertEqual(reloaded?.revision, 0)
    }

    func testProfileGetOrCreateKeepsScopeUnique() async throws {
        let container = try makeMemoryContainer()
        let store = MemoryStore(modelContainer: container)
        let first = try await store.getOrCreateProfile(scopeID: MemoryScope.localDefault)
        let second = try await store.getOrCreateProfile(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(first.id, second.id)

        let context = ModelContext(container)
        let profiles = try context.fetch(FetchDescriptor<UserMemoryProfile>())
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.scopeID, MemoryScope.localDefault)
    }

    func testMemoryCRUDClampsScoresAndKeepsEmbeddingNil() async throws {
        let store = MemoryStore(modelContainer: try makeMemoryContainer())
        let inserted = try await store.insertMemory(
            scopeID: MemoryScope.localDefault,
            draft: .init(kind: .preference, canonicalText: "  Prefers tables  ", importance: 2, confidence: -1)
        )
        XCTAssertEqual(inserted.canonicalText, "Prefers tables")
        XCTAssertEqual(inserted.importance, 1)
        XCTAssertEqual(inserted.confidence, 0)
        XCTAssertNil(inserted.embeddingData)
        let fetchedAfterInsert = try await store.memory(id: inserted.id, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(fetchedAfterInsert, inserted)

        let updated = MemoryItemSnapshot(
            id: inserted.id,
            scopeID: inserted.scopeID,
            kindRawValue: MemoryKind.ongoingContext.rawValue,
            canonicalText: "Working on long-term memory",
            embeddingData: nil,
            importance: 0.8,
            confidence: 0.9,
            statusRawValue: MemoryStatus.active.rawValue,
            createdAt: inserted.createdAt,
            updatedAt: inserted.updatedAt.addingTimeInterval(1),
            lastReinforcedAt: inserted.updatedAt,
            expiresAt: nil,
            reinforcementCount: 1
        )
        let saved = try await store.updateMemory(updated)
        XCTAssertEqual(saved.canonicalText, updated.canonicalText)
        XCTAssertEqual(saved.kind, .ongoingContext)
        XCTAssertEqual(saved.reinforcementCount, 1)
        let listedAfterUpdate = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(listedAfterUpdate.count, 1)

        let deleted = try await store.deleteMemory(id: inserted.id, scopeID: MemoryScope.localDefault)
        let fetchedAfterDelete = try await store.memory(id: inserted.id, scopeID: MemoryScope.localDefault)
        let listedAfterDelete = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertTrue(deleted)
        XCTAssertNil(fetchedAfterDelete)
        XCTAssertTrue(listedAfterDelete.isEmpty)
    }

    func testMultipleSourcesPersistAndCascadeWithMemoryDeletion() async throws {
        let store = MemoryStore(modelContainer: try makeMemoryContainer())
        let memory = try await store.insertMemory(
            scopeID: MemoryScope.localDefault,
            draft: .init(kind: .durableFact, canonicalText: "A durable fact")
        )
        let conversationA = UUID(), userA = UUID(), assistantA = UUID()
        let conversationB = UUID(), userB = UUID(), assistantB = UUID()
        let fingerprintA = CompletedTurnFingerprint.make(conversationID: conversationA, userMessageID: userA, assistantMessageID: assistantA)
        let fingerprintB = CompletedTurnFingerprint.make(conversationID: conversationB, userMessageID: userB, assistantMessageID: assistantB)

        _ = try await store.addSource(
            memoryItemID: memory.id,
            scopeID: MemoryScope.localDefault,
            draft: .init(sourceConversationID: conversationA, userMessageID: userA, assistantMessageID: assistantA, turnFingerprint: fingerprintA)
        )
        _ = try await store.addSource(
            memoryItemID: memory.id,
            scopeID: MemoryScope.localDefault,
            draft: .init(sourceConversationID: conversationB, userMessageID: userB, assistantMessageID: assistantB, turnFingerprint: fingerprintB)
        )

        let sources = try await store.sources(memoryItemID: memory.id, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(Set(sources.map(\.sourceConversationID)), Set([conversationA, conversationB]))
        let sourceToUpdate = try XCTUnwrap(sources.first(where: { $0.sourceConversationID == conversationA }))
        let replacementConversationID = UUID()
        let updatedSource = MemorySourceSnapshot(
            id: sourceToUpdate.id,
            scopeID: sourceToUpdate.scopeID,
            memoryItemID: sourceToUpdate.memoryItemID,
            sourceConversationID: replacementConversationID,
            userMessageID: sourceToUpdate.userMessageID,
            assistantMessageID: sourceToUpdate.assistantMessageID,
            turnFingerprint: sourceToUpdate.turnFingerprint,
            createdAt: sourceToUpdate.createdAt
        )
        let savedSource = try await store.updateSource(updatedSource)
        XCTAssertEqual(savedSource.sourceConversationID, replacementConversationID)
        let processedBeforeDelete = try await store.hasProcessedTurn(scopeID: MemoryScope.localDefault, turnFingerprint: fingerprintA)
        XCTAssertTrue(processedBeforeDelete)

        let sourceB = try XCTUnwrap(sources.first(where: { $0.sourceConversationID == conversationB }))
        let deletedSource = try await store.deleteSource(id: sourceB.id, scopeID: MemoryScope.localDefault)
        let sourcesAfterSourceDelete = try await store.sources(memoryItemID: memory.id, scopeID: MemoryScope.localDefault)
        XCTAssertTrue(deletedSource)
        XCTAssertEqual(sourcesAfterSourceDelete.count, 1)

        let deleted = try await store.deleteMemory(id: memory.id, scopeID: MemoryScope.localDefault)
        let sourcesAfterDelete = try await store.sources(memoryItemID: memory.id, scopeID: MemoryScope.localDefault)
        let processedAfterDelete = try await store.hasProcessedTurn(scopeID: MemoryScope.localDefault, turnFingerprint: fingerprintA)
        XCTAssertTrue(deleted)
        XCTAssertTrue(sourcesAfterDelete.isEmpty)
        XCTAssertFalse(processedAfterDelete)
    }

    func testMemoryAndSourceGraphPersistsAcrossContainerReload() async throws {
        let location = try temporaryStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let memoryID = UUID()
        let conversationA = UUID(), userA = UUID(), assistantA = UUID()
        let conversationB = UUID(), userB = UUID(), assistantB = UUID()
        let fingerprintA = CompletedTurnFingerprint.make(
            conversationID: conversationA,
            userMessageID: userA,
            assistantMessageID: assistantA
        )
        let fingerprintB = CompletedTurnFingerprint.make(
            conversationID: conversationB,
            userMessageID: userB,
            assistantMessageID: assistantB
        )

        try await writeMemoryGraph(
            to: location.store,
            memoryID: memoryID,
            sources: [
                .init(
                    sourceConversationID: conversationA,
                    userMessageID: userA,
                    assistantMessageID: assistantA,
                    turnFingerprint: fingerprintA
                ),
                .init(
                    sourceConversationID: conversationB,
                    userMessageID: userB,
                    assistantMessageID: assistantB,
                    turnFingerprint: fingerprintB
                )
            ]
        )

        let container = try makeFullContainer(at: location.store)
        let store = MemoryStore(modelContainer: container)
        let memory = try await store.memory(id: memoryID, scopeID: MemoryScope.localDefault)
        let sources = try await store.sources(memoryItemID: memoryID, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(memory?.canonicalText, "Persistent memory")
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(Set(sources.map(\.sourceConversationID)), Set([conversationA, conversationB]))
        XCTAssertEqual(Set(sources.map(\.turnFingerprint)), Set([fingerprintA, fingerprintB]))

        _ = try await store.deleteMemory(id: memoryID, scopeID: MemoryScope.localDefault)
        let remainingSources = try await store.sources(memoryItemID: memoryID, scopeID: MemoryScope.localDefault)
        XCTAssertTrue(remainingSources.isEmpty)
    }

    func testStaleProfileRevisionCannotOverwriteNewerWrite() async throws {
        let store = MemoryStore(modelContainer: try makeMemoryContainer())
        let initial = try await store.getOrCreateProfile(scopeID: MemoryScope.localDefault)
        let revisionOne = try await store.updateProfile(
            scopeID: MemoryScope.localDefault,
            expectedRevision: initial.revision,
            payload: .init(durable: ["one"])
        )
        let revisionTwo = try await store.updateProfile(
            scopeID: MemoryScope.localDefault,
            expectedRevision: revisionOne.revision,
            payload: .init(durable: ["two"])
        )
        let readerA = revisionTwo
        let readerB = revisionTwo

        let revisionThree = try await store.updateProfile(
            scopeID: MemoryScope.localDefault,
            expectedRevision: readerB.revision,
            payload: .init(durable: ["writer B"])
        )
        XCTAssertEqual(revisionThree.revision, 3)

        do {
            _ = try await store.updateProfile(
                scopeID: MemoryScope.localDefault,
                expectedRevision: readerA.revision,
                payload: .init(durable: ["stale writer A"])
            )
            XCTFail("Expected revision conflict")
        } catch let error as MemoryError {
            XCTAssertEqual(error, .revisionConflict(expected: 2, actual: 3))
        }

        let optionalFinal = try await store.profile(scopeID: MemoryScope.localDefault)
        let final = try XCTUnwrap(optionalFinal)
        XCTAssertEqual(final.payload.durable, ["writer B"])
        XCTAssertEqual(final.revision, 3)
    }

    func testConcurrentProfileReadsListsAndInsertsRemainIsolated() async throws {
        let store = MemoryStore(modelContainer: try makeMemoryContainer())
        _ = try await store.getOrCreateProfile(scopeID: MemoryScope.localDefault)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    switch index % 3 {
                    case 0:
                        _ = try await store.getOrCreateProfile(scopeID: MemoryScope.localDefault)
                    case 1:
                        _ = try await store.listMemories(scopeID: MemoryScope.localDefault)
                    default:
                        _ = try await store.insertMemory(
                            scopeID: MemoryScope.localDefault,
                            draft: .init(kind: .event, canonicalText: "Concurrent memory \(index)")
                        )
                    }
                }
            }
            try await group.waitForAll()
        }

        let memories = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(memories.count, 10)
        XCTAssertEqual(Set(memories.map(\.canonicalText)).count, 10)
    }

    func testMemoryServiceUsesDefaultLocalScopeWithoutCreatingChatHooks() async throws {
        let service = MemoryService(modelContainer: try makeMemoryContainer())
        let profile = try await service.getUserProfile()
        let memories = try await service.listMemories()
        XCTAssertEqual(profile.scopeID, MemoryScope.localDefault)
        XCTAssertTrue(memories.isEmpty)
    }

    func testAdditiveSchemaEvolutionPreservesExistingConversationsAndCascadeRule() async throws {
        let location = try temporaryStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try seedLegacyStore(at: location.store)

        let newContainer = try makeFullContainer(at: location.store)
        let context = ModelContext(newContainer)
        let conversations = try context.fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\Conversation.title)]))
        let messages = try context.fetch(FetchDescriptor<ChatMessage>())
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(messages.count, 3)

        let first = try XCTUnwrap(conversations.first(where: { $0.title == "Conversation A" }))
        let second = try XCTUnwrap(conversations.first(where: { $0.title == "Conversation B" }))
        XCTAssertEqual(first.systemPrompt, "System A")
        XCTAssertEqual(second.systemPrompt, "System B")
        XCTAssertEqual(first.messages.count, 2)
        XCTAssertEqual(Set(first.messages.map(\.content)), Set(["Question A", "Answer A"]))
        XCTAssertEqual(second.messages.count, 1)
        XCTAssertEqual(second.messages.first?.content, "Question B")
        XCTAssertTrue(first.messages.allSatisfy { $0.conversation?.id == first.id })
        XCTAssertTrue(second.messages.allSatisfy { $0.conversation?.id == second.id })

        context.delete(first)
        try context.save()
        let remainingConversations = try context.fetch(FetchDescriptor<Conversation>())
        let remainingMessages = try context.fetch(FetchDescriptor<ChatMessage>())
        XCTAssertEqual(remainingConversations.map(\.title), ["Conversation B"])
        XCTAssertEqual(remainingMessages.map(\.content), ["Question B"])

        let memoryStore = MemoryStore(modelContainer: newContainer)
        let inserted = try await memoryStore.insertMemory(
            scopeID: MemoryScope.localDefault,
            draft: .init(kind: .event, canonicalText: "Created after migration")
        )
        let fetched = try await memoryStore.memory(id: inserted.id, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(fetched?.canonicalText, "Created after migration")
        let updated = MemoryItemSnapshot(
            id: inserted.id,
            scopeID: inserted.scopeID,
            kindRawValue: MemoryKind.ongoingContext.rawValue,
            canonicalText: "Updated after migration",
            embeddingData: nil,
            importance: inserted.importance,
            confidence: inserted.confidence,
            statusRawValue: inserted.statusRawValue,
            createdAt: inserted.createdAt,
            updatedAt: inserted.updatedAt.addingTimeInterval(1),
            lastReinforcedAt: nil,
            expiresAt: nil,
            reinforcementCount: inserted.reinforcementCount
        )
        let saved = try await memoryStore.updateMemory(updated)
        XCTAssertEqual(saved.canonicalText, "Updated after migration")
        let deleted = try await memoryStore.deleteMemory(id: inserted.id, scopeID: MemoryScope.localDefault)
        XCTAssertTrue(deleted)
        let deletedMemory = try await memoryStore.memory(id: inserted.id, scopeID: MemoryScope.localDefault)
        XCTAssertNil(deletedMemory)
    }

    private func makeMemoryContainer() throws -> ModelContainer {
        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        let configuration = ModelConfiguration(
            "MemoryTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func fullSchema() -> Schema {
        Schema([
            Conversation.self,
            ChatMessage.self,
            LocalKnowledgeBase.self,
            LocalKnowledgeDocument.self,
            LocalKnowledgeChunk.self,
            UserMemoryProfile.self,
            MemoryItem.self,
            MemorySource.self,
            MemoryTurnRecord.self
        ])
    }

    private func legacySchema() -> Schema {
        Schema([
            Conversation.self,
            ChatMessage.self,
            LocalKnowledgeBase.self,
            LocalKnowledgeDocument.self,
            LocalKnowledgeChunk.self
        ])
    }

    private func makeFullContainer(at url: URL) throws -> ModelContainer {
        let schema = fullSchema()
        let configuration = ModelConfiguration("Default", schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func seedLegacyStore(at url: URL) throws {
        let schema = legacySchema()
        let configuration = ModelConfiguration("Default", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let conversationA = Conversation(title: "Conversation A", systemPrompt: "System A")
        let conversationB = Conversation(title: "Conversation B", systemPrompt: "System B")
        context.insert(conversationA)
        context.insert(conversationB)
        context.insert(ChatMessage(role: "user", content: "Question A", conversation: conversationA))
        context.insert(ChatMessage(role: "assistant", content: "Answer A", conversation: conversationA))
        context.insert(ChatMessage(role: "user", content: "Question B", conversation: conversationB))
        try context.save()
    }

    private func temporaryStoreLocation() throws -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("default.store"))
    }

    private func writeProfile(to url: URL) async throws {
        let container = try makeFullContainer(at: url)
        let store = MemoryStore(modelContainer: container)
        let initial = try await store.getOrCreateProfile(scopeID: MemoryScope.localDefault)
        _ = try await store.updateProfile(
            scopeID: MemoryScope.localDefault,
            expectedRevision: initial.revision,
            payload: .init(preferences: ["prefers concise answers"], recentFocus: ["memory design"])
        )
    }

    private func writeEmptyProfile(to url: URL) async throws -> UserMemoryProfileSnapshot {
        let container = try makeFullContainer(at: url)
        let store = MemoryStore(modelContainer: container)
        return try await store.getOrCreateProfile(scopeID: MemoryScope.localDefault)
    }

    private func readProfile(from url: URL) async throws -> UserMemoryProfileSnapshot {
        let container = try makeFullContainer(at: url)
        let store = MemoryStore(modelContainer: container)
        let profile = try await store.profile(scopeID: MemoryScope.localDefault)
        return try XCTUnwrap(profile)
    }

    private func writeMemoryGraph(
        to url: URL,
        memoryID: UUID,
        sources: [MemorySourceDraft]
    ) async throws {
        let container = try makeFullContainer(at: url)
        let store = MemoryStore(modelContainer: container)
        _ = try await store.insertMemory(
            scopeID: MemoryScope.localDefault,
            draft: .init(id: memoryID, kind: .event, canonicalText: "Persistent memory")
        )
        for source in sources {
            _ = try await store.addSource(
                memoryItemID: memoryID,
                scopeID: MemoryScope.localDefault,
                draft: source
            )
        }
    }
}
