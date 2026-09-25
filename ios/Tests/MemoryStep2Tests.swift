import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

@MainActor
final class MemoryStep2Tests: XCTestCase {
    func testValidatorAcceptsAddAndPreference() throws {
        let projectTurn = makeTurn(user: "我正在开发一个 DeepSeek iOS 客户端。")
        let project = response(.init(
            action: "add",
            existingMemoryID: nil,
            kind: MemoryKind.ongoingContext.rawValue,
            canonicalText: "用户正在开发一个 DeepSeek iOS 客户端。",
            importance: 0.8,
            confidence: 0.96
        ))
        XCTAssertEqual(
            try MemoryOperationValidator.validate(response: project, turn: projectTurn, candidates: []),
            [.add(kind: .ongoingContext, canonicalText: "用户正在开发一个 DeepSeek iOS 客户端。", importance: 0.8, confidence: 0.96)]
        )

        let preferenceTurn = makeTurn(user: "我更喜欢节奏紧凑、结局难猜的电影。")
        let preference = response(.init(
            action: "add",
            existingMemoryID: nil,
            kind: MemoryKind.preference.rawValue,
            canonicalText: "用户喜欢节奏紧凑、结局难猜的电影。",
            importance: 0.75,
            confidence: 0.95
        ))
        XCTAssertEqual(try MemoryOperationValidator.validate(response: preference, turn: preferenceTurn, candidates: []).count, 1)
    }

    func testValidatorRejectsThirdPartyHypotheticalSecretInvalidIDAndInvalidScore() throws {
        let unsafeCases: [(String, String)] = [
            ("我朋友最近在准备司法考试。", "用户最近在准备司法考试。"),
            ("假设我住在东京，该怎么安排生活？", "用户住在东京。"),
            ("我的 API key 是 sk-example-secret。", "用户的 API key 是 sk-example-secret。")
        ]
        for (user, canonical) in unsafeCases {
            let value = response(.init(
                action: "add", existingMemoryID: nil, kind: MemoryKind.recentState.rawValue,
                canonicalText: canonical, importance: 0.8, confidence: 0.9
            ))
            XCTAssertThrowsError(try MemoryOperationValidator.validate(response: value, turn: makeTurn(user: user), candidates: []))
        }

        let candidate = ExistingMemoryCandidate(
            id: UUID(), kind: .preference, canonicalText: "用户喜欢紧凑的电影。",
            importance: 0.7, confidence: 0.9, updatedAt: Date()
        )
        let invalidID = response(.init(
            action: "reinforce", existingMemoryID: UUID().uuidString, kind: MemoryKind.preference.rawValue,
            canonicalText: "用户喜欢紧凑的电影。", importance: 0.8, confidence: 0.95
        ))
        XCTAssertThrowsError(try MemoryOperationValidator.validate(
            response: invalidID,
            turn: makeTurn(user: "我还是喜欢紧凑的电影。"),
            candidates: [candidate]
        ))

        let invalidScore = response(.init(
            action: "add", existingMemoryID: nil, kind: MemoryKind.preference.rawValue,
            canonicalText: "用户喜欢紧凑的电影。", importance: 5, confidence: 0.9
        ))
        XCTAssertThrowsError(try MemoryOperationValidator.validate(
            response: invalidScore,
            turn: makeTurn(user: "我喜欢紧凑的电影。"),
            candidates: []
        ))
    }

    func testEmptyExtractionProducesNoOperations() throws {
        let turn = makeTurn(user: "矩阵的秩是什么意思？")
        let validated = try MemoryOperationValidator.validate(
            response: .init(schemaVersion: 1, operations: []),
            turn: turn,
            candidates: []
        )
        XCTAssertTrue(validated.isEmpty)
    }

    func testAddReinforceSupersedeIntegration() async throws {
        let container = try makeMemoryContainer()
        let store = MemoryStore(modelContainer: container)
        let extractor = ScriptedMemoryExtractor(plans: [
            .response(response(.init(
                action: "add", existingMemoryID: nil, kind: MemoryKind.recentState.rawValue,
                canonicalText: "用户近期正在复习线性代数。", importance: 0.7, confidence: 0.95
            ))),
            .reinforceFirst,
            .supersedeFirst(kind: .recentState, text: "用户近期开始复习交通工程。")
        ])
        let processor = MemoryProcessor(store: store, extractor: extractor)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        let firstTurn = makeTurn(user: "我最近正在复习线性代数。", completedAt: base)
        let firstResult = await processor.processCompletedTurn(firstTurn)
        guard case .processed(operationCount: 1, _) = firstResult else { return XCTFail("Expected ADD") }
        var memories = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(memories.count, 1)
        let original = try XCTUnwrap(memories.first)
        XCTAssertEqual(original.status, .active)
        XCTAssertEqual(original.reinforcementCount, 0)
        let originalSources = try await store.sources(memoryItemID: original.id, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(originalSources.count, 1)
        let firstExpiration = try XCTUnwrap(original.expiresAt)

        let secondTurn = makeTurn(user: "这几天我还是在复习线性代数。", completedAt: base.addingTimeInterval(86_400))
        let secondResult = await processor.processCompletedTurn(secondTurn)
        guard case .processed(operationCount: 1, _) = secondResult else { return XCTFail("Expected REINFORCE") }
        memories = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(memories.count, 1)
        let reinforced = try XCTUnwrap(memories.first)
        XCTAssertEqual(reinforced.reinforcementCount, 1)
        let reinforcedSources = try await store.sources(memoryItemID: reinforced.id, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(reinforcedSources.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(reinforced.expiresAt), firstExpiration)

        let thirdTurn = makeTurn(user: "线性代数先告一段落，现在开始复习交通工程。", completedAt: base.addingTimeInterval(172_800))
        let thirdResult = await processor.processCompletedTurn(thirdTurn)
        guard case .processed(operationCount: 1, _) = thirdResult else { return XCTFail("Expected SUPERSEDE") }
        memories = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(memories.count, 2)
        let old = try XCTUnwrap(memories.first(where: { $0.id == original.id }))
        let replacement = try XCTUnwrap(memories.first(where: { $0.id != original.id }))
        XCTAssertEqual(old.status, .superseded)
        XCTAssertEqual(replacement.status, .active)
        XCTAssertEqual(replacement.kind, .recentState)
        XCTAssertEqual(replacement.canonicalText, "用户近期开始复习交通工程。")
        let replacementSources = try await store.sources(memoryItemID: replacement.id, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(replacementSources.count, 1)
    }

    func testNoopTurnIsIdempotentAndDoesNotCallExtractorTwice() async throws {
        let container = try makeMemoryContainer()
        let store = MemoryStore(modelContainer: container)
        let extractor = ScriptedMemoryExtractor(plans: [.response(.init(schemaVersion: 1, operations: []))])
        let processor = MemoryProcessor(store: store, extractor: extractor)
        let turn = makeTurn(user: "矩阵的秩是什么意思？")

        let first = await processor.processCompletedTurn(turn)
        let second = await processor.processCompletedTurn(turn)
        guard case .noop = first else { return XCTFail("Expected noop") }
        XCTAssertEqual(second, .alreadyProcessed(status: .noop))
        let calls = await extractor.callCount
        XCTAssertEqual(calls, 1)
        let noopMemories = try await store.listMemories(scopeID: MemoryScope.localDefault)
        let noopRecord = try await store.turnRecord(processingKey: turn.processingKey)
        XCTAssertTrue(noopMemories.isEmpty)
        XCTAssertEqual(noopRecord?.status, .noop)
    }

    func testSuccessfulTurnIsIdempotent() async throws {
        let container = try makeMemoryContainer()
        let store = MemoryStore(modelContainer: container)
        let extractor = ScriptedMemoryExtractor(plans: [.response(response(.init(
            action: "add", existingMemoryID: nil, kind: MemoryKind.ongoingContext.rawValue,
            canonicalText: "用户正在开发 DeepSeek iOS 客户端。", importance: 0.8, confidence: 0.95
        )))])
        let processor = MemoryProcessor(store: store, extractor: extractor)
        let turn = makeTurn(user: "我正在开发 DeepSeek iOS 客户端。")

        _ = await processor.processCompletedTurn(turn)
        let second = await processor.processCompletedTurn(turn)
        XCTAssertEqual(second, .alreadyProcessed(status: .succeeded))
        let callCount = await extractor.callCount
        XCTAssertEqual(callCount, 1)
        let memories = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(memories.count, 1)
        let sources = try await store.sources(memoryItemID: memories[0].id, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(sources.count, 1)
    }

    func testFailedExtractionCanRetryAndSucceed() async throws {
        let container = try makeMemoryContainer()
        let store = MemoryStore(modelContainer: container)
        let extractor = ScriptedMemoryExtractor(plans: [
            .failure(.networkError),
            .response(response(.init(
                action: "add", existingMemoryID: nil, kind: MemoryKind.preference.rawValue,
                canonicalText: "用户喜欢节奏紧凑的电影。", importance: 0.7, confidence: 0.9
            )))
        ])
        let processor = MemoryProcessor(store: store, extractor: extractor)
        let turn = makeTurn(user: "我喜欢节奏紧凑的电影。")

        let failedResult = await processor.processCompletedTurn(turn)
        let failedRecord = try await store.turnRecord(processingKey: turn.processingKey)
        let memoriesAfterFailure = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(failedResult, .failed(code: "network_error"))
        XCTAssertEqual(failedRecord?.status, .failed)
        XCTAssertTrue(memoriesAfterFailure.isEmpty)

        guard case .processed(operationCount: 1, _) = await processor.processCompletedTurn(turn) else {
            return XCTFail("Expected retry success")
        }
        let retryCalls = await extractor.callCount
        let successfulRecord = try await store.turnRecord(processingKey: turn.processingKey)
        let memoriesAfterRetry = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(retryCalls, 2)
        XCTAssertEqual(successfulRecord?.status, .succeeded)
        XCTAssertEqual(memoriesAfterRetry.count, 1)
    }

    func testBatchSaveFailureRollsBackEveryMutation() async throws {
        let container = try makeMemoryContainer()
        let store = MemoryStore(modelContainer: container)
        let old = try await store.insertMemory(
            scopeID: MemoryScope.localDefault,
            draft: .init(kind: .recentState, canonicalText: "用户近期正在复习线性代数。")
        )
        let turn = makeTurn(user: "我现在开始复习交通工程，也在准备英语考试。")
        await store.injectNextBatchSaveFailureForTesting()
        do {
            _ = try await store.applyMemoryOperations([
                .add(kind: .ongoingContext, canonicalText: "用户正在准备英语考试。", importance: 0.7, confidence: 0.9),
                .add(kind: .preference, canonicalText: "用户偏好使用结构化复习计划。", importance: 0.6, confidence: 0.8),
                .supersede(existingMemoryID: old.id, kind: .recentState, canonicalText: "用户近期开始复习交通工程。", importance: 0.8, confidence: 0.95)
            ], for: turn, extractorVersion: 1, modelName: "mock")
            XCTFail("Expected injected persistence failure")
        } catch let error as MemoryError {
            guard case .persistenceFailure = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let memories = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.id, old.id)
        XCTAssertEqual(memories.first?.status, .active)
        let rolledBackRecord = try await store.turnRecord(processingKey: turn.processingKey)
        XCTAssertNil(rolledBackRecord)
    }

    func testCompletionEligibilityRejectsCancelledFailedPartialAndEmptyTurns() {
        let values = [
            CompletedTurnEligibility.snapshot(successfulCompletion: false, persistenceSucceeded: true, conversationID: UUID(), userMessageID: UUID(), userText: "用户消息", assistantMessageID: UUID(), assistantText: "partial"),
            CompletedTurnEligibility.snapshot(successfulCompletion: true, persistenceSucceeded: false, conversationID: UUID(), userMessageID: UUID(), userText: "用户消息", assistantMessageID: UUID(), assistantText: "回答"),
            CompletedTurnEligibility.snapshot(successfulCompletion: true, persistenceSucceeded: true, conversationID: UUID(), userMessageID: UUID(), userText: "用户消息", assistantMessageID: UUID(), assistantText: "")
        ]
        XCTAssertTrue(values.allSatisfy { $0 == nil })
        XCTAssertNotNil(CompletedTurnEligibility.snapshot(
            successfulCompletion: true,
            persistenceSucceeded: true,
            conversationID: UUID(),
            userMessageID: UUID(),
            userText: "用户消息",
            assistantMessageID: UUID(),
            assistantText: "完整回答"
        ))
    }

    func testMemoryFailureDoesNotMutateSavedChat() async throws {
        let container = try makeAppContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let conversation = Conversation(title: "Original", systemPrompt: "Original system")
        let user = ChatMessage(role: "user", content: "我正在开发客户端。", conversation: conversation)
        let assistant = ChatMessage(role: "assistant", content: "已保存的完整回答", reasoning: "不会提供给 Memory", conversation: conversation)
        context.insert(conversation); context.insert(user); context.insert(assistant)
        try context.save()
        let store = MemoryStore(modelContainer: container)
        let extractor = ScriptedMemoryExtractor(plans: [
            .failure(.timeout),
            .failure(.decodeError),
            .failure(.emptyContent),
            .failure(.httpError(500)),
            .response(response(.init(
                action: "add", existingMemoryID: nil, kind: MemoryKind.ongoingContext.rawValue,
                canonicalText: "用户正在开发客户端。", importance: 0.8, confidence: 0.9
            )))
        ])
        let processor = MemoryProcessor(store: store, extractor: extractor)
        for expectedCode in ["timeout", "decode_error", "empty_content", "http_500"] {
            let turn = CompletedTurnSnapshot(
                conversationID: conversation.id,
                userMessageID: UUID(),
                userText: user.content,
                assistantMessageID: UUID(),
                assistantText: assistant.content
            )
            let result = await processor.processCompletedTurn(turn)
            XCTAssertEqual(result, .failed(code: expectedCode))
        }

        await store.injectNextBatchSaveFailureForTesting()
        let persistenceTurn = CompletedTurnSnapshot(
            conversationID: conversation.id,
            userMessageID: UUID(),
            userText: user.content,
            assistantMessageID: UUID(),
            assistantText: assistant.content
        )
        let persistenceResult = await processor.processCompletedTurn(persistenceTurn)
        XCTAssertEqual(persistenceResult, .failed(code: "persistence_error"))
        let memories = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertTrue(memories.isEmpty)

        XCTAssertEqual(conversation.title, "Original")
        XCTAssertEqual(conversation.systemPrompt, "Original system")
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(user.content, "我正在开发客户端。")
        XCTAssertEqual(assistant.content, "已保存的完整回答")
        XCTAssertEqual(assistant.reasoning, "不会提供给 Memory")
    }

    func testStepOneStoreMigratesToMemoryTurnRecordSchema() async throws {
        let location = try temporaryStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try seedStepOneStore(at: location.store)

        let container = try makeAppContainer(at: location.store)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserMemoryProfile>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemoryItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemorySource>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemoryTurnRecord>()), 0)

        let store = MemoryStore(modelContainer: container)
        let turn = makeTurn(user: "矩阵的秩是什么？")
        let result = try await store.applyMemoryOperations([], for: turn, extractorVersion: 1, modelName: "mock")
        guard case .applied(let record, 0) = result else { return XCTFail("Expected noop turn record") }
        XCTAssertEqual(record.status, .noop)
        let records = try await store.listTurnRecords(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemoryItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemorySource>()), 1)
    }

    private func response(_ operation: MemoryExtractionOperation) -> MemoryExtractionResponse {
        .init(schemaVersion: 1, operations: [operation])
    }

    private func makeTurn(user: String, completedAt: Date = Date()) -> CompletedTurnSnapshot {
        .init(
            conversationID: UUID(),
            userMessageID: UUID(),
            userText: user,
            assistantMessageID: UUID(),
            assistantText: "已完成回答。",
            completedAt: completedAt
        )
    }

    private func makeMemoryContainer() throws -> ModelContainer {
        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        let configuration = ModelConfiguration("Step2MemoryTests", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func appSchema(includeTurnRecord: Bool = true) -> Schema {
        var models: [any PersistentModel.Type] = [
            Conversation.self, ChatMessage.self,
            LocalKnowledgeBase.self, LocalKnowledgeDocument.self, LocalKnowledgeChunk.self,
            UserMemoryProfile.self, MemoryItem.self, MemorySource.self
        ]
        if includeTurnRecord { models.append(MemoryTurnRecord.self) }
        return Schema(models)
    }

    private func makeAppContainer(isStoredInMemoryOnly: Bool) throws -> ModelContainer {
        let schema = appSchema()
        let configuration = ModelConfiguration("Step2AppTests", schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeAppContainer(at url: URL) throws -> ModelContainer {
        let schema = appSchema()
        let configuration = ModelConfiguration("Default", schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func seedStepOneStore(at url: URL) throws {
        let schema = appSchema(includeTurnRecord: false)
        let configuration = ModelConfiguration("Default", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let conversation = Conversation(title: "Preserved", systemPrompt: "Preserved system")
        context.insert(conversation)
        context.insert(ChatMessage(role: "user", content: "Preserved user", conversation: conversation))
        context.insert(ChatMessage(role: "assistant", content: "Preserved assistant", conversation: conversation))
        let profileData = try JSONEncoder().encode(UserMemoryProfilePayload(preferences: ["preserved"]))
        context.insert(UserMemoryProfile(scopeID: MemoryScope.localDefault, profileData: profileData))
        let item = MemoryItem(
            scopeID: MemoryScope.localDefault,
            kindRawValue: MemoryKind.preference.rawValue,
            canonicalText: "用户偏好保留的数据。"
        )
        let source = MemorySource(
            scopeID: MemoryScope.localDefault,
            sourceConversationID: conversation.id,
            userMessageID: conversation.messages.first(where: { $0.role == "user" })?.id,
            assistantMessageID: conversation.messages.first(where: { $0.role == "assistant" })?.id,
            turnFingerprint: "step-one-source"
        )
        item.sources.append(source)
        context.insert(item); context.insert(source)
        try context.save()
    }

    private func temporaryStoreLocation() throws -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-step2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("default.store"))
    }
}

private actor ScriptedMemoryExtractor: MemoryExtracting {
    enum Plan: Sendable {
        case response(MemoryExtractionResponse)
        case reinforceFirst
        case supersedeFirst(kind: MemoryKind, text: String)
        case failure(MemoryProcessingError)
    }

    nonisolated let modelName = "mock-memory-extractor"
    private var plans: [Plan]
    private(set) var callCount = 0

    init(plans: [Plan]) { self.plans = plans }

    func extract(turn: CompletedTurnSnapshot, candidates: [ExistingMemoryCandidate]) async throws -> MemoryExtractionOutput {
        callCount += 1
        guard !plans.isEmpty else { throw MemoryProcessingError.networkError }
        let plan = plans.removeFirst()
        let response: MemoryExtractionResponse
        switch plan {
        case .response(let value): response = value
        case .failure(let error): throw error
        case .reinforceFirst:
            guard let candidate = candidates.first else { throw MemoryProcessingError.validationRejected }
            response = .init(schemaVersion: 1, operations: [.init(
                action: "reinforce",
                existingMemoryID: candidate.id.uuidString,
                kind: candidate.kind.rawValue,
                canonicalText: candidate.canonicalText,
                importance: min(1, candidate.importance + 0.1),
                confidence: min(1, candidate.confidence + 0.02)
            )])
        case .supersedeFirst(let kind, let text):
            guard let candidate = candidates.first else { throw MemoryProcessingError.validationRejected }
            response = .init(schemaVersion: 1, operations: [.init(
                action: "supersede",
                existingMemoryID: candidate.id.uuidString,
                kind: kind.rawValue,
                canonicalText: text,
                importance: 0.8,
                confidence: 0.95
            )])
        }
        return .init(
            response: response,
            metrics: .init(
                latencyMilliseconds: 1,
                inputCharacters: turn.userText.count + turn.assistantText.count,
                outputBytes: 1,
                operationCount: response.operations.count,
                promptTokens: nil,
                completionTokens: nil,
                totalTokens: nil
            )
        )
    }
}
