import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

@MainActor
final class UserProfileManagerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSyntheticFixtureAppliesLimitsSafetyStatusExpiryAndDeterministicOrdering() {
        var items: [MemoryItemSnapshot] = []
        for index in 0..<12 {
            items.append(memory(index, kind: .durableFact, text: "用户拥有稳定设备 \(index)。", ageDays: index == 0 ? 365 : Double(index), importance: index == 0 ? 1 : 0.6))
            items.append(memory(100 + index, kind: .preference, text: "用户偏好电影类型 \(index)。", ageDays: Double(index)))
        }
        for index in 0..<8 {
            items.append(memory(200 + index, kind: .ongoingContext, text: "用户正在进行项目 \(index)。", ageDays: Double(index), expiresInDays: 60))
            items.append(memory(300 + index, kind: .recentState, text: "用户近期状态 \(index)。", ageDays: Double(index), expiresInDays: 7))
        }
        items += [
            memory(401, kind: .preference, text: "用户喜欢旧偏好。", status: .superseded),
            memory(402, kind: .recentState, text: "用户近期正在复习已过期内容。", ageDays: 20, expiresInDays: -1),
            memory(403, kind: .durableFact, text: "用户的 API key 是 sk-sensitive。"),
            memory(
                404, kind: .event, text: "用户已经完成项目 A。", ageDays: 1,
                importance: 1, confidence: 1, reinforcementCount: 5
            ),
            memory(405, kind: .preference, text: "用户不再偏好慢节奏电影，更喜欢节奏紧凑的电影。", ageDays: 1, reinforcementCount: 5)
        ]

        let first = UserProfileManager.derive(memories: items, scopeID: MemoryScope.localDefault, now: now)
        let second = UserProfileManager.derive(memories: Array(items.reversed()), scopeID: MemoryScope.localDefault, now: now)
        XCTAssertEqual(first.payload, second.payload)
        XCTAssertEqual(first.payload.durable.count, 8)
        XCTAssertEqual(first.payload.preferences.count, 8)
        XCTAssertEqual(first.payload.ongoing.count, 6)
        XCTAssertEqual(first.payload.recentState.count, 6)
        XCTAssertEqual(first.payload.recentFocus.count, 5)
        XCTAssertTrue(first.payload.durable.contains { $0.text == "用户拥有稳定设备 0。" }, "old high-value durable fact must survive")
        let all = allEntries(first.payload)
        XCTAssertFalse(all.contains { $0.text.contains("旧偏好") })
        XCTAssertFalse(all.contains { $0.text.contains("已过期") })
        XCTAssertFalse(all.contains { $0.text.lowercased().contains("api key") })
        XCTAssertTrue(first.payload.recentFocus.contains { $0.text == "用户已经完成项目 A。" })
        XCTAssertEqual(Set(first.payload.durable.flatMap(\.sourceMemoryIDs)).count, first.payload.durable.count)
    }

    func testPreferenceSupersessionAndOngoingCompletionKeepOnlyCurrentMeaning() {
        let items = [
            memory(1, kind: .preference, text: "用户喜欢慢节奏艺术电影。", status: .superseded),
            memory(2, kind: .preference, text: "用户不再偏好慢节奏艺术电影，更喜欢节奏紧凑的电影。"),
            memory(3, kind: .ongoingContext, text: "用户正在开发项目 A。", status: .superseded),
            memory(4, kind: .event, text: "用户已完成项目 A。", ageDays: 1)
        ]
        let payload = UserProfileManager.derive(memories: items, scopeID: MemoryScope.localDefault, now: now).payload
        XCTAssertEqual(payload.preferences.map(\.text), ["用户不再偏好慢节奏艺术电影，更喜欢节奏紧凑的电影。"])
        XCTAssertTrue(payload.ongoing.isEmpty)
        XCTAssertTrue(payload.recentFocus.contains { $0.text == "用户已完成项目 A。" })
    }

    func testReinforcementGivesBoundedAdvantage() {
        let plain = memory(1, kind: .durableFact, text: "用户使用设备 A。", reinforcementCount: 0)
        let reinforced = memory(2, kind: .durableFact, text: "用户使用设备 B。", reinforcementCount: 20)
        let result = UserProfileManager.derive(
            memories: [plain, reinforced], scopeID: MemoryScope.localDefault, now: now,
            configuration: .init(maximumDurable: 1)
        )
        XCTAssertEqual(result.payload.durable.first?.sourceMemoryIDs, [reinforced.id])
        XCTAssertLessThan(MemoryReinforcementSaturation.score(count: 20), 1)
        XCTAssertGreaterThan(MemoryReinforcementSaturation.score(count: 1), 0)
    }

    func testRecentFocusRotatesWhileLongTermSectionsRemain() {
        let dayZero = [
            memory(1, kind: .ongoingContext, text: "用户正在进行项目 A。", ageDays: 25, expiresInDays: 65),
            memory(2, kind: .preference, text: "用户偏好节奏紧凑的电影。", ageDays: 25),
            memory(3, kind: .durableFact, text: "用户是建筑学本科生。", ageDays: 365),
            memory(4, kind: .recentState, text: "用户近期关注交通工程。", ageDays: 0, expiresInDays: 14),
            memory(5, kind: .ongoingContext, text: "用户正在开发 Memory 系统。", ageDays: 0, expiresInDays: 90)
        ]
        let payload = UserProfileManager.derive(memories: dayZero, scopeID: MemoryScope.localDefault, now: now).payload
        XCTAssertTrue(payload.durable.contains { $0.text.contains("建筑学") })
        XCTAssertTrue(payload.preferences.contains { $0.text.contains("电影") })
        XCTAssertEqual(Set(payload.recentFocus.prefix(2).map(\.text)), Set(["用户近期关注交通工程。", "用户正在开发 Memory 系统。"]))
    }

    func testTTLReadRebuildsAndRevisionOnlyChangesWhenSourceChanges() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        let manager = UserProfileManager(store: store)
        let item = try await store.insertMemory(
            scopeID: MemoryScope.localDefault,
            draft: .init(
                kind: .recentState, canonicalText: "用户近期正在复习线性代数。",
                importance: 0.8, confidence: 0.95, createdAt: now,
                updatedAt: now, lastConfirmedAt: now, expiresAt: now.addingTimeInterval(86_400)
            )
        )
        let first = try await manager.profileSnapshot(now: now)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.payload.recentState.map(\.text), [item.canonicalText])
        XCTAssertEqual(first.payload.nextRefreshAt, item.expiresAt)

        let noop = try await manager.profileSnapshot(now: now.addingTimeInterval(60))
        XCTAssertEqual(noop.revision, first.revision)
        XCTAssertEqual(noop.payload.generatedAt, first.payload.generatedAt)

        let expired = try await manager.profileSnapshot(now: now.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(expired.revision, first.revision + 1)
        XCTAssertTrue(expired.payload.recentState.isEmpty)
        XCTAssertTrue(expired.payload.recentFocus.isEmpty)
    }

    func testV1PayloadIsDiscardedAndRebuiltOnlyFromActiveMemory() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let legacy = Data(#"{"schemaVersion":1,"durable":["invented legacy fact"],"preferences":[],"ongoing":[],"recentState":[],"recentFocus":[]}"#.utf8)
        context.insert(UserMemoryProfile(scopeID: MemoryScope.localDefault, profileData: legacy))
        context.insert(MemoryItem(
            id: id(7), scopeID: MemoryScope.localDefault, kindRawValue: MemoryKind.durableFact.rawValue,
            canonicalText: "用户是建筑学本科生。", importance: 0.9, confidence: 0.95,
            createdAt: now, updatedAt: now, lastConfirmedAt: now
        ))
        try context.save()

        let snapshot = try await UserProfileManager(store: MemoryStore(modelContainer: container)).profileSnapshot(now: now)
        XCTAssertEqual(snapshot.payload.schemaVersion, 2)
        XCTAssertEqual(snapshot.payload.durable.map(\.text), ["用户是建筑学本科生。"])
        XCTAssertFalse(snapshot.payload.durable.contains { $0.text.contains("legacy") })
    }

    func testStep4PersistentStoreAndV1ProfileSurviveStep5Open() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("step5-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("default.store")
        let schema = fullSchema()
        do {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(
                "Default", schema: schema, url: url, cloudKitDatabase: .none
            )])
            let context = ModelContext(container)
            let conversation = Conversation(title: "Preserved", systemPrompt: "Preserved system")
            let user = ChatMessage(role: "user", content: "Preserved user", conversation: conversation)
            let assistant = ChatMessage(role: "assistant", content: "Preserved assistant", conversation: conversation)
            let knowledge = LocalKnowledgeBase(name: "Preserved knowledge")
            let document = LocalKnowledgeDocument(name: "note.txt", mediaType: "text/plain", byteCount: 4, knowledgeBase: knowledge)
            let chunk = LocalKnowledgeChunk(index: 0, text: "note", embedding: Data([1]), document: document)
            knowledge.documents.append(document); document.chunks.append(chunk)
            let memory = MemoryItem(
                id: id(700), scopeID: MemoryScope.localDefault,
                kindRawValue: MemoryKind.preference.rawValue,
                canonicalText: "用户偏好保留迁移数据。", importance: 0.8, confidence: 0.9,
                createdAt: now, updatedAt: now, lastConfirmedAt: now
            )
            let source = MemorySource(
                scopeID: MemoryScope.localDefault, sourceConversationID: conversation.id,
                userMessageID: user.id, assistantMessageID: assistant.id,
                turnFingerprint: "migration-source", createdAt: now
            )
            memory.sources.append(source)
            let profileData = Data(#"{"schemaVersion":1,"durable":[],"preferences":["legacy cache"],"ongoing":[],"recentState":[],"recentFocus":[]}"#.utf8)
            let profile = UserMemoryProfile(scopeID: MemoryScope.localDefault, profileData: profileData)
            let turn = MemoryTurnRecord(
                scopeID: MemoryScope.localDefault, processingKey: "migration-turn",
                turnFingerprint: "migration-turn", sourceConversationID: conversation.id,
                userMessageID: user.id, assistantMessageID: assistant.id,
                statusRawValue: MemoryTurnStatus.succeeded.rawValue,
                extractorVersion: 5, createdAt: now, updatedAt: now
            )
            context.insert(conversation); context.insert(user); context.insert(assistant)
            context.insert(knowledge); context.insert(document); context.insert(chunk)
            context.insert(memory); context.insert(source); context.insert(profile); context.insert(turn)
            try context.save()
        }

        let reopened = try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "Default", schema: schema, url: url, cloudKitDatabase: .none
        )])
        let context = ModelContext(reopened)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalKnowledgeBase>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalKnowledgeDocument>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalKnowledgeChunk>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemoryItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemorySource>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemoryTurnRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserMemoryProfile>()), 1)
        let snapshot = try await UserProfileManager(store: MemoryStore(modelContainer: reopened)).profileSnapshot(now: now)
        XCTAssertEqual(snapshot.payload.preferences.map(\.text), ["用户偏好保留迁移数据。"])
        XCTAssertEqual(snapshot.revision, 1)
    }

    func testCrossConversationProvenanceDoesNotPartitionUserProfile() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        for value in 1...2 {
            let item = try await store.insertMemory(
                scopeID: MemoryScope.localDefault,
                draft: .init(id: id(800 + value), kind: .durableFact, canonicalText: "用户跨会话事实 \(value)。", lastConfirmedAt: now)
            )
            let conversationID = UUID()
            _ = try await store.addSource(
                memoryItemID: item.id, scopeID: MemoryScope.localDefault,
                draft: .init(sourceConversationID: conversationID, turnFingerprint: "conversation-\(value)")
            )
        }
        let profile = try await UserProfileManager(store: store).profileSnapshot(now: now)
        XCTAssertEqual(Set(profile.payload.durable.map(\.text)), Set(["用户跨会话事实 1。", "用户跨会话事实 2。"]))
    }

    func testNoopAndRetrievalDoNotChangeProfileRevisionOrDigest() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        _ = try await store.insertMemory(
            scopeID: MemoryScope.localDefault,
            draft: .init(kind: .preference, canonicalText: "用户偏好节奏紧凑的电影。", lastConfirmedAt: now)
        )
        let manager = UserProfileManager(store: store)
        let first = try await manager.profileSnapshot(now: now)
        let noopProcessor = MemoryProcessor(store: store, extractor: ProfileNoopExtractor())
        let ordinaryQuestion = CompletedTurnSnapshot(
            conversationID: UUID(), userMessageID: UUID(), userText: "法国首都是什么？",
            assistantMessageID: UUID(), assistantText: "巴黎。", completedAt: now
        )
        guard case .noop = await noopProcessor.processCompletedTurn(ordinaryQuestion) else {
            return XCTFail("Ordinary question must produce a Memory NOOP")
        }
        let retriever = MemoryRetriever(store: store, semanticResolver: nil)
        for _ in 0..<100 {
            _ = try await retriever.search(.init(primaryText: "推荐电影"), now: now)
        }
        let after = try await manager.profileSnapshot(now: now)
        XCTAssertEqual(after.revision, first.revision)
        XCTAssertEqual(after.payload.sourceDigest, first.payload.sourceDigest)
        XCTAssertEqual(after.payload, first.payload)
    }

    func testProfileDerivationCannotChangeStep4Request() {
        let history = [ChatMessage(role: "assistant", content: "earlier")]
        let context = MemoryContextBuilder.build(
            results: [retrievalResult()], currentUserText: "再推荐一部电影。", now: now
        ).context
        let before = ChatRequestAssembler.messages(
            system: "system", history: history, memoryContext: context, newUserText: "再推荐一部电影。"
        )
        _ = UserProfileManager.derive(
            memories: [memory(1, kind: .durableFact, text: "用户是建筑学本科生。")],
            scopeID: MemoryScope.localDefault, now: now
        )
        let after = ChatRequestAssembler.messages(
            system: "system", history: history, memoryContext: context, newUserText: "再推荐一部电影。"
        )
        XCTAssertEqual(after, before)
    }

    func testConcurrentProcessorProfileRefreshAndRetrieverRemainConsistent() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        let extractor = ProfileTestExtractor()
        let processor = MemoryProcessor(store: store, extractor: extractor)
        let manager = UserProfileManager(store: store)
        let retriever = MemoryRetriever(store: store, semanticResolver: nil)
        let currentNow = now
        let turn = CompletedTurnSnapshot(
            conversationID: UUID(), userMessageID: UUID(), userText: "我正在开发 Memory 系统。",
            assistantMessageID: UUID(), assistantText: "好的。", completedAt: currentNow
        )

        async let write = processor.processCompletedTurn(turn)
        async let refresh = manager.refreshIfNeeded(now: currentNow)
        async let read = retriever.search(.init(primaryText: "Memory 系统"), now: currentNow)
        let writeResult = await write
        _ = try await refresh
        _ = try await read
        guard case .processed = writeResult else { return XCTFail("Expected successful processor write") }
        let final = try await manager.profileSnapshot(now: currentNow)
        XCTAssertEqual(final.payload.ongoing.map(\.text), ["用户正在开发 Memory 系统。"])
        XCTAssertEqual(final.payload.ongoing.first?.sourceMemoryIDs.count, 1)
    }

    func testMemoryServiceSchedulesProfileRefreshOnlyAfterMutation() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        let service = MemoryService(
            store: store,
            processor: MemoryProcessor(store: store, extractor: ProfileTestExtractor())
        )
        let turn = CompletedTurnSnapshot(
            conversationID: UUID(), userMessageID: UUID(), userText: "我正在开发 Memory 系统。",
            assistantMessageID: UUID(), assistantText: "好的。", completedAt: now
        )
        guard case .processed = await service.processCompletedTurn(turn) else {
            return XCTFail("Expected successful Memory mutation")
        }
        var refreshed: UserMemoryProfileSnapshot?
        for _ in 0..<200 {
            if let value = try await store.profile(scopeID: MemoryScope.localDefault), value.revision > 0 {
                refreshed = value
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(refreshed?.payload.ongoing.map(\.text), ["用户正在开发 Memory 系统。"])
    }

    private func allEntries(_ payload: UserMemoryProfilePayload) -> [ProfileEntry] {
        payload.durable + payload.preferences + payload.ongoing + payload.recentState + payload.recentFocus
    }

    private func memory(
        _ value: Int,
        kind: MemoryKind,
        text: String,
        status: MemoryStatus = .active,
        ageDays: Double = 0,
        expiresInDays: Double? = nil,
        importance: Double = 0.8,
        confidence: Double = 0.9,
        reinforcementCount: Int = 0
    ) -> MemoryItemSnapshot {
        let confirmed = now.addingTimeInterval(-ageDays * 86_400)
        return .init(
            id: id(value), scopeID: MemoryScope.localDefault, kindRawValue: kind.rawValue,
            canonicalText: text, embeddingData: nil, importance: importance, confidence: confidence,
            statusRawValue: status.rawValue, createdAt: confirmed, updatedAt: confirmed,
            lastConfirmedAt: confirmed, lastReinforcedAt: reinforcementCount > 0 ? confirmed : nil,
            expiresAt: expiresInDays.map { now.addingTimeInterval($0 * 86_400) },
            reinforcementCount: reinforcementCount
        )
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "ProfileTests", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
    }

    private func fullSchema() -> Schema {
        Schema([
            Conversation.self, ChatMessage.self,
            LocalKnowledgeBase.self, LocalKnowledgeDocument.self, LocalKnowledgeChunk.self,
            UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self
        ])
    }

    private func retrievalResult() -> MemoryRetrievalResult {
        .init(
            memoryID: id(99), kind: .preference, canonicalText: "用户偏好节奏紧凑的电影。",
            semanticAvailable: false, semanticScore: 0, lexicalScore: 1, entityMatch: true,
            relevanceScore: 1, recencyScore: 1, importanceScore: 0.8,
            reinforcementScore: 0, finalScore: 0.9, rank: 1,
            lastConfirmedAt: now, expiresAt: nil
        )
    }
}

private actor ProfileTestExtractor: MemoryExtracting {
    nonisolated let modelName = "profile-test"

    func extract(turn: CompletedTurnSnapshot, candidates: [ExistingMemoryCandidate]) async throws -> MemoryExtractionOutput {
        .init(
            response: .init(schemaVersion: 1, operations: [.init(
                action: "add", existingMemoryID: nil, kind: MemoryKind.ongoingContext.rawValue,
                canonicalText: "用户正在开发 Memory 系统。", importance: 0.85, confidence: 0.98
            )]),
            metrics: .init(
                latencyMilliseconds: 0, inputCharacters: turn.userText.count, outputBytes: 0,
                operationCount: 1, promptTokens: nil, completionTokens: nil, totalTokens: nil
            )
        )
    }
}

private actor ProfileNoopExtractor: MemoryExtracting {
    nonisolated let modelName = "profile-noop-test"

    func extract(turn: CompletedTurnSnapshot, candidates: [ExistingMemoryCandidate]) async throws -> MemoryExtractionOutput {
        .init(
            response: .init(schemaVersion: 1, operations: []),
            metrics: .init(
                latencyMilliseconds: 0, inputCharacters: turn.userText.count, outputBytes: 0,
                operationCount: 0, promptTokens: nil, completionTokens: nil, totalTokens: nil
            )
        )
    }
}
