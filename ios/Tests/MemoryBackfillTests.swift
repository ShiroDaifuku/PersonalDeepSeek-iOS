import XCTest
import SwiftData
@testable import PersonalDeepSeek

final class MemoryBackfillTests: XCTestCase {
    func testScannerPairsOnlyUnambiguousFinalAssistantAndSortsGlobally() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let newer = Conversation(title: "newer")
        let older = Conversation(title: "older")
        context.insert(newer); context.insert(older)
        addTurn(to: newer, context: context, user: "new user", assistant: "new answer", at: date(2025, 6, 1))
        addTurn(to: older, context: context, user: "old user", assistant: "old answer", at: date(2024, 1, 1))
        let dangling = ChatMessage(role: "user", content: "dangling", conversation: older)
        dangling.createdAt = date(2024, 2, 1)
        context.insert(dangling)
        let reasoningOnlyUser = ChatMessage(role: "user", content: "reasoning only", conversation: older)
        reasoningOnlyUser.createdAt = date(2024, 3, 1)
        let reasoningOnlyAssistant = ChatMessage(role: "assistant", content: "", reasoning: "private", conversation: older)
        reasoningOnlyAssistant.createdAt = date(2024, 3, 1).addingTimeInterval(1)
        context.insert(reasoningOnlyUser); context.insert(reasoningOnlyAssistant)
        try context.save()

        let scan = try await HistoricalTurnScanner(modelContainer: container).scan()
        XCTAssertEqual(scan.conversationCount, 2)
        XCTAssertEqual(scan.turns.map(\.userText), ["old user", "new user"])
        XCTAssertEqual(scan.dangling, 2)
        XCTAssertTrue(scan.turns.allSatisfy { $0.completedAt < date(2026, 1, 1) })
    }

    func testHistoricalExpiredEphemeralIsNoopAndNeverPersisted() async throws {
        let container = try makeContainer()
        let store = MemoryStore(modelContainer: container)
        let extractor = BackfillScriptedExtractor(plans: [.add(.recentState, "用户这几天在复习线性代数。")])
        let processor = MemoryProcessor(store: store, extractor: extractor)
        let turn = historicalTurn(
            user: "我这几天在复习线性代数。",
            assistant: "好的。",
            at: date(2024, 1, 1)
        )
        let details = await processor.processCompletedTurnDetailed(turn)
        guard case .noop = details.result else { return XCTFail("Expected historical expired NOOP") }
        XCTAssertEqual(details.skippedExpiredEphemeral, 1)
        let memories = try await store.listMemories(scopeID: MemoryScope.localDefault)
        let record = try await store.turnRecord(processingKey: turn.processingKey)
        XCTAssertEqual(memories.count, 0)
        XCTAssertEqual(record?.status, .noop)
    }

    func testHistoricalReinforcementCannotRegressConfirmationOrExpiration() async throws {
        let container = try makeContainer()
        let store = MemoryStore(modelContainer: container)
        let currentDate = date(2026, 9, 1)
        let item = try await store.insertMemory(scopeID: MemoryScope.localDefault, draft: .init(
            kind: .ongoingContext,
            canonicalText: "用户正在开发项目 A。",
            createdAt: currentDate,
            updatedAt: currentDate,
            lastConfirmedAt: currentDate,
            expiresAt: currentDate.addingTimeInterval(90 * 86_400)
        ))
        let historical = historicalTurn(user: "我正在开发项目 A。", assistant: "明白。", at: date(2026, 8, 1))
        _ = try await store.applyMemoryOperations(
            [.reinforce(existingMemoryID: item.id, importance: 0.8, confidence: 0.9)],
            for: historical,
            extractorVersion: 6,
            modelName: "test",
            now: date(2026, 9, 28)
        )
        let updated = try XCTUnwrap(try await store.memory(id: item.id, scopeID: MemoryScope.localDefault))
        XCTAssertEqual(updated.lastConfirmedAt, currentDate)
        XCTAssertEqual(updated.expiresAt, currentDate.addingTimeInterval(90 * 86_400))
        let sources = try await store.sources(memoryItemID: item.id, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(sources.first?.evidenceAt, historical.completedAt)
        XCTAssertEqual(sources.first?.createdAt, date(2026, 9, 28))
    }

    func testStoreRejectsTemporalInversionSupersede() async throws {
        let container = try makeContainer()
        let store = MemoryStore(modelContainer: container)
        let current = date(2026, 9, 1)
        let item = try await store.insertMemory(scopeID: MemoryScope.localDefault, draft: .init(
            kind: .preference,
            canonicalText: "用户偏好节奏紧凑的电影。",
            createdAt: current,
            updatedAt: current,
            lastConfirmedAt: current
        ))
        let oldTurn = historicalTurn(user: "我喜欢慢节奏电影。", assistant: "知道了。", at: date(2024, 1, 1))
        let result = try await store.applyMemoryOperations(
            [.supersede(existingMemoryID: item.id, kind: .preference, canonicalText: "用户偏好慢节奏电影。", importance: 0.8, confidence: 0.9)],
            for: oldTurn,
            extractorVersion: 6,
            modelName: "test"
        )
        guard case .applied(let record, let count) = result else { return XCTFail("Expected recorded NOOP") }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(record.status, .noop)
        let unchanged = try await store.memory(id: item.id, scopeID: MemoryScope.localDefault)
        let all = try await store.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertEqual(unchanged?.status, .active)
        XCTAssertEqual(all.count, 1)
    }

    func testCoordinatorIsIdempotentAndSecondRunMakesZeroExtractorCalls() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let conversation = Conversation(title: "history")
        context.insert(conversation)
        addTurn(to: conversation, context: context, user: "我是建筑学本科生。", assistant: "明白。", at: date(2024, 1, 1))
        try context.save()
        let store = MemoryStore(modelContainer: container)
        let extractor = BackfillScriptedExtractor(plans: [.add(.durableFact, "用户是建筑学本科生。")])
        let processor = MemoryProcessor(store: store, extractor: extractor)
        let manager = UserProfileManager(store: store)
        let coordinator = MemoryBackfillCoordinator(
            scanner: HistoricalTurnScanner(modelContainer: container),
            store: store,
            processor: processor,
            profileManager: manager
        )
        let preflight = try await coordinator.preflight()
        XCTAssertEqual(preflight.estimatedRequestCount, 1)
        let first = await coordinator.start()
        XCTAssertEqual(first.requests, 1)
        XCTAssertEqual(first.succeeded, 1)
        let second = await coordinator.start()
        XCTAssertEqual(second.requests, 0)
        XCTAssertEqual(second.skippedAlreadyProcessed, 1)
        let calls = await extractor.calls()
        XCTAssertEqual(calls, 1)
    }

    func testMaintenanceHoldDisablesReadyProfileAndReconcilesAfterRelease() async throws {
        let container = try makeContainer()
        let store = MemoryStore(modelContainer: container)
        _ = try await store.insertMemory(scopeID: MemoryScope.localDefault, draft: .init(
            kind: .durableFact,
            canonicalText: "用户使用 RTX 4070 Laptop GPU。"
        ))
        let manager = UserProfileManager(store: store)
        _ = try await manager.refreshIfNeeded()
        let readyBefore = await manager.readyProfileForChat()
        XCTAssertNotNil(readyBefore)
        await manager.beginMaintenanceHold()
        let held = await manager.readyProfileForChat()
        XCTAssertNil(held)
        await manager.endMaintenanceHold()
        for _ in 0..<50 {
            if await manager.readyProfileForChat() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let readyAfter = await manager.readyProfileForChat()
        XCTAssertNotNil(readyAfter)
    }

    func testPreflightPerformanceAt1001000And5000Turns() async throws {
        for count in [100, 1_000, 5_000] {
            let container = try makeContainer()
            let context = ModelContext(container)
            let conversation = Conversation(title: "performance-\(count)")
            context.insert(conversation)
            let base = date(2020, 1, 1)
            for index in 0..<count {
                addTurn(
                    to: conversation,
                    context: context,
                    user: "用户消息 \(index)",
                    assistant: "助手回答 \(index)",
                    at: base.addingTimeInterval(Double(index * 2))
                )
            }
            try context.save()
            let store = MemoryStore(modelContainer: container)
            let processor = MemoryProcessor(store: store, extractor: BackfillScriptedExtractor(plans: []))
            let coordinator = MemoryBackfillCoordinator(
                scanner: HistoricalTurnScanner(modelContainer: container),
                store: store,
                processor: processor,
                profileManager: UserProfileManager(store: store)
            )
            let report = try await coordinator.preflight()
            XCTAssertEqual(report.eligibleTurnCount, count)
            XCTAssertEqual(report.estimatedRequestCount, count)
            XCTAssertGreaterThanOrEqual(report.performance.totalMilliseconds, 0)
            print(
                "[BackfillPreflight] turns=\(count) fetch_ms=\(report.performance.fetchMilliseconds) " +
                "pairing_ms=\(report.performance.pairingMilliseconds) records_ms=\(report.performance.turnRecordMilliseconds) " +
                "sort_ms=\(report.performance.sortMilliseconds) total_ms=\(report.performance.totalMilliseconds)"
            )
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Conversation.self, ChatMessage.self,
            UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "BackfillTests", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
    }

    private func addTurn(
        to conversation: Conversation,
        context: ModelContext,
        user: String,
        assistant: String,
        at completedAt: Date
    ) {
        let userMessage = ChatMessage(role: "user", content: user, conversation: conversation)
        userMessage.createdAt = completedAt.addingTimeInterval(-1)
        let assistantMessage = ChatMessage(role: "assistant", content: assistant, conversation: conversation)
        assistantMessage.createdAt = completedAt
        context.insert(userMessage); context.insert(assistantMessage)
    }

    private func historicalTurn(user: String, assistant: String, at: Date) -> CompletedTurnSnapshot {
        .init(
            conversationID: UUID(),
            userMessageID: UUID(),
            userText: user,
            assistantMessageID: UUID(),
            assistantText: assistant,
            completedAt: at,
            origin: .historicalBackfill
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0), year: year, month: month, day: day
        ))!
    }
}

private actor BackfillScriptedExtractor: MemoryExtracting {
    enum Plan: Sendable {
        case add(MemoryKind, String)
    }
    nonisolated let modelName = "backfill-test"
    private var plans: [Plan]
    private var callCount = 0
    init(plans: [Plan]) { self.plans = plans }

    func calls() -> Int { callCount }

    func extract(turn: CompletedTurnSnapshot, candidates: [ExistingMemoryCandidate]) async throws -> MemoryExtractionOutput {
        callCount += 1
        guard !plans.isEmpty else { throw MemoryProcessingError.networkError }
        let plan = plans.removeFirst()
        let operation: MemoryExtractionOperation = switch plan {
        case .add(let kind, let text): .init(
            action: "add", existingMemoryID: nil, kind: kind.rawValue,
            canonicalText: text, importance: 0.8, confidence: 0.95
        )
        }
        let response = MemoryExtractionResponse(schemaVersion: 1, operations: [operation])
        return .init(response: response, metrics: .init(
            latencyMilliseconds: 1,
            inputCharacters: turn.userText.count + turn.assistantText.count,
            outputBytes: 1,
            operationCount: 1,
            promptTokens: 10,
            completionTokens: 5,
            totalTokens: 15
        ))
    }
}
