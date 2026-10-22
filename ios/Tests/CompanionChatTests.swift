import XCTest
import SwiftData
@testable import PersonalDeepSeek

@MainActor
final class CompanionChatTests: XCTestCase {
    func testModeRestorationAndPersonaBoundaries() {
        XCTAssertEqual(ChatExperienceMode.restored("companion"), .companion)
        XCTAssertEqual(ChatExperienceMode.restored("assistant"), .assistant)
        XCTAssertEqual(ChatExperienceMode.restored("unknown-future-mode"), .assistant)
        XCTAssertTrue(CompanionChatPolicy.persona.contains("不是剧本"))
        XCTAssertTrue(CompanionChatPolicy.persona.contains("主人"))
        XCTAssertTrue(CompanionChatPolicy.persona.contains("没有联网"))
        XCTAssertFalse(CompanionChatPolicy.persona.contains("1798474868"))
        XCTAssertFalse(CompanionChatPolicy.persona.contains("shukishuki"))
        XCTAssertFalse(CompanionChatPolicy.persona.contains("记忆管理"))
    }

    func testSegmentsNeverLoseTextEvenBeyondThreeOr140Characters() {
        let input = "在。\n真的在！这是第三句？第四句。" + String(repeating: "完整内容", count: 100)
        let segments = CompanionChatPolicy.segments(input)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.joined(), input)
        XCTAssertEqual(CompanionChatPolicy.segments("在。"), ["在。"])
        XCTAssertEqual(CompanionChatPolicy.segments(""), [])
    }

    func testCompanionSamplingIsOptInAndOrdinaryWireUnchanged() throws {
        let messages = [APIMessage(role: "user", content: "在吗")]
        let companion = CompanionChatPolicy.request(messages: messages)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.requestBody(companion)) as? [String: Any])
        XCTAssertEqual(body["temperature"] as? Double, 0.85)
        XCTAssertEqual(body["max_tokens"] as? Int, 600)
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(body["tools"])
        let ordinary = AgentModelRequest(messages: messages, model: "deepseek-v4-pro", thinking: true,
            reasoningEffort: "high", toolNames: [], toolChoice: .auto)
        let originalExpected: [String: Any] = ["model": "deepseek-v4-pro", "stream": true,
            "messages": [["role": "user", "content": "在吗"]], "thinking": ["type": "enabled"],
            "reasoning_effort": "high", "stream_options": ["include_usage": true]]
        XCTAssertEqual(try JSONSerialization.jsonObject(with: APIClient.requestBody(ordinary)) as? NSDictionary,
                       originalExpected as NSDictionary)
        var invalid = ordinary
        invalid.temperature = .nan
        XCTAssertThrowsError(try APIClient.requestBody(invalid))
        invalid.temperature = 3
        XCTAssertThrowsError(try APIClient.requestBody(invalid))
    }

    func testBoundedHistoryUsesOnlySuppliedConversationWithoutChangingStoredHistory() {
        let conversation = Conversation(mode: "companion")
        for index in 0..<30 {
            let message = ChatMessage(role: index.isMultiple(of: 2) ? "user" : "assistant", content: "message-\(index)")
            message.createdAt = Date(timeIntervalSince1970: Double(index)); conversation.messages.append(message)
        }
        let history = CompanionChatViewModel.boundedHistory(conversation.messages)
        XCTAssertEqual(history.count, 12)
        XCTAssertEqual(history.first?.content, "message-18")
        XCTAssertEqual(conversation.messages.count, 30)
        let huge = ChatMessage(role: "user", content: String(repeating: "中", count: 2_001))
        XCTAssertTrue(CompanionChatViewModel.boundedHistory([huge]).isEmpty)
    }

    func testCompletedTurnPersistsFullAnswerAndUsesExistingMemoryPipeline() async throws {
        let fixture = try makeFixture(deltas: [.content("在。"), .content("\n真的在。第三句。第四句。"), .finishReason("stop"), .done])
        fixture.model.send("我喜欢简洁回答", context: fixture.container.mainContext)
        await fixture.model.waitUntilIdle()
        let conversation = try XCTUnwrap(fixture.model.current)
        XCTAssertEqual(conversation.mode, "companion")
        XCTAssertEqual(conversation.systemPrompt, CompanionChatPolicy.persona)
        let assistant = try XCTUnwrap(conversation.messages.first(where: { $0.role == "assistant" }))
        XCTAssertEqual(assistant.content, "在。\n真的在。第三句。第四句。")
        XCTAssertEqual(CompanionChatPolicy.segments(assistant.content).joined(), assistant.content)
        for _ in 0..<100 {
            if await fixture.extractor.count() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let turns = await fixture.extractor.turns
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.scopeID, MemoryScope.localDefault)
        XCTAssertEqual(turns.first?.conversationID, conversation.id)
        XCTAssertEqual(turns.first?.assistantText, assistant.content)
        XCTAssertEqual(turns.first?.completedAt, assistant.createdAt)
        let requests = await fixture.recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.messages.first?.content, MessagePrefix.systemContent(system: conversation.systemPrompt))
        XCTAssertTrue(requests.first?.messages.contains(where: { $0.content.contains("Application runtime clock") }) ?? false)
        XCTAssertNil(fixture.model.errorText)
    }

    func testCancelledTurnHasNoAssistantOrMemoryExtraction() async throws {
        let fixture = try makeFixture(deltas: [.content("未完成")], delay: true)
        fixture.model.send("测试取消", context: fixture.container.mainContext)
        fixture.model.cancel()
        await fixture.model.waitUntilIdle()
        XCTAssertFalse(fixture.model.isGenerating)
        XCTAssertTrue(fixture.model.current?.messages.filter { $0.role == "assistant" }.isEmpty ?? false)
        let count = await fixture.extractor.count()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(fixture.model.errorText?.contains("已停止") ?? false)
    }

    func testTruncatedAndDisconnectedAnswersNeverBecomeCompletedTurns() async throws {
        let cases: [[StreamDelta]] = [[.content("未完成"), .finishReason("length"), .done], [.content("连接中断")]]
        for events in cases {
            let fixture = try makeFixture(deltas: events)
            fixture.model.send("测试失败", context: fixture.container.mainContext)
            await fixture.model.waitUntilIdle()
            XCTAssertTrue(fixture.model.current?.messages.filter { $0.role == "assistant" }.isEmpty ?? false)
            let count = await fixture.extractor.count()
            XCTAssertEqual(count, 0)
            XCTAssertNotNil(fixture.model.errorText)
        }
    }

    func testCannotSelectOrdinaryConversationOrCreateEmptyConversation() throws {
        let fixture = try makeFixture(deltas: [])
        let ordinary = Conversation(systemPrompt: "ordinary system")
        fixture.model.select(ordinary)
        XCTAssertNil(fixture.model.current)
        fixture.model.send("  \n", context: fixture.container.mainContext)
        XCTAssertEqual(try fixture.container.mainContext.fetchCount(FetchDescriptor<Conversation>()), 0)
        XCTAssertEqual(ordinary.systemPrompt, "ordinary system")
        fixture.model.send(String(repeating: "中", count: 4_001), context: fixture.container.mainContext)
        XCTAssertNil(fixture.model.current)
    }

    func testSharedUserScopeDoesNotReplayOtherConversationSystemOrHistory() async throws {
        let fixture = try makeFixture(deltas: [.content("在。"), .finishReason("stop"), .done])
        let ordinary = Conversation(systemPrompt: "ORDINARY_SYSTEM_SENTINEL")
        fixture.container.mainContext.insert(ordinary)
        fixture.container.mainContext.insert(ChatMessage(role: "user", content: "ORDINARY_HISTORY_SENTINEL", conversation: ordinary))
        let companion = Conversation(systemPrompt: CompanionChatPolicy.persona, mode: "companion")
        fixture.container.mainContext.insert(companion)
        fixture.container.mainContext.insert(ChatMessage(role: "user", content: "COMPANION_HISTORY_SENTINEL", conversation: companion))
        try fixture.container.mainContext.save()
        let store = MemoryStore(modelContainer: fixture.container)
        let inserted = try await store.insertMemory(scopeID: MemoryScope.localDefault,
            draft: .init(kind: .preference, canonicalText: "用户喜欢简洁回答。", importance: 0.8, confidence: 0.95))
        let shared = try await fixture.service.listMemories(scopeID: MemoryScope.localDefault)
        XCTAssertTrue(shared.contains(where: { $0.id == inserted.id }))
        fixture.model.select(companion)
        fixture.model.send("在吗", context: fixture.container.mainContext)
        await fixture.model.waitUntilIdle()
        let recorded = await fixture.recorder.firstRequest()
        let request = try XCTUnwrap(recorded)
        XCTAssertTrue(request.messages.contains(where: { $0.content == "COMPANION_HISTORY_SENTINEL" }))
        XCTAssertFalse(request.messages.contains(where: { $0.content.contains("ORDINARY_SYSTEM_SENTINEL") || $0.content.contains("ORDINARY_HISTORY_SENTINEL") }))
        XCTAssertEqual(ordinary.systemPrompt, "ORDINARY_SYSTEM_SENTINEL")
        XCTAssertEqual(ordinary.messages.count, 1)
    }

    private func makeFixture(deltas: [StreamDelta], delay: Bool = false) throws -> CompanionFixture {
        let schema = Schema([Conversation.self, ChatMessage.self, UserMemoryProfile.self, MemoryItem.self,
            MemorySource.self, MemoryTurnRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let extractor = CompanionRecordingExtractor()
        let service = MemoryService(modelContainer: container, extractor: extractor)
        let recorder = CompanionRequestRecorder()
        let model = CompanionChatViewModel(memoryService: service,
            client: CompanionStubModel(deltas: deltas, delay: delay, recorder: recorder))
        return .init(container: container, model: model, extractor: extractor, recorder: recorder, service: service)
    }
}

@MainActor
private struct CompanionFixture {
    let container: ModelContainer
    let model: CompanionChatViewModel
    let extractor: CompanionRecordingExtractor
    let recorder: CompanionRequestRecorder
    let service: MemoryService
}

private actor CompanionRequestRecorder {
    var requests: [AgentModelRequest] = []
    func record(_ request: AgentModelRequest) { requests.append(request) }
    func firstRequest() -> AgentModelRequest? { requests.first }
}

private struct CompanionStubModel: AgentModelStreaming {
    let deltas: [StreamDelta]
    let delay: Bool
    let recorder: CompanionRequestRecorder
    func streamRound(_ request: AgentModelRequest) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await recorder.record(request)
                do {
                    if delay { try await Task.sleep(for: .seconds(10)) }
                    for delta in deltas { try Task.checkCancellation(); continuation.yield(delta) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor CompanionRecordingExtractor: MemoryExtracting {
    nonisolated let modelName = "companion-test-noop"
    var turns: [CompletedTurnSnapshot] = []
    func count() -> Int { turns.count }
    func extract(turn: CompletedTurnSnapshot, candidates: [ExistingMemoryCandidate]) async throws -> MemoryExtractionOutput {
        turns.append(turn)
        return .init(response: .init(schemaVersion: 1, operations: []),
            metrics: .init(latencyMilliseconds: 0, inputCharacters: turn.userText.count, outputBytes: 0,
                operationCount: 0, promptTokens: nil, completionTokens: nil, totalTokens: nil))
    }
}
