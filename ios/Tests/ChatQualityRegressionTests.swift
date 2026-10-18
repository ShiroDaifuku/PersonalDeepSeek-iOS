import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

@MainActor final class ChatQualityRegressionTests: XCTestCase {
    func testRewritingOrdinaryObjectsDoesNotEditTasks() {
        for text in ["如果把这道题改成考研数学一的试题，会怎么改？", "把函数改成分段函数", "把这段话改成英文", "把界面改成深色"] {
            XCTAssertNil(AssistantIntentRouter.preferredTool(for: text), text)
        }
        for text in ["把任务改成每天十点", "把之前的提醒改成晚上九点", "暂停任务", "恢复任务", "edit task", "reschedule my reminder"] {
            XCTAssertEqual(AssistantIntentRouter.preferredTool(for: text), "edit_scheduled_task", text)
        }
        XCTAssertEqual(AssistantIntentRouter.preferredTool(for: "明天提醒我复习"), "create_scheduled_task")
        XCTAssertEqual(AssistantIntentRouter.preferredTool(for: "联网搜索最新考试大纲"), "web_search")
        XCTAssertEqual(AssistantIntentRouter.preferredTool(for: "从我的笔记查极限"), "search_local_knowledge")
    }
    private func saved(_ service: ToolExecutionService, conversation: UUID, query: String, title: String, snippet: String) async throws -> UUID {
        let execution = try await service.begin(conversationID: conversation, userMessageID: UUID(), assistantMessageID: UUID(), toolName: "web_search", query: query)
        _ = try await service.succeed(id: execution.id, envelope: ToolResultEnvelopeBuilder.webSearch(toolName: "web_search", query: query,
            provider: "fixture", sources: [.init(title: title, url: URL(string: "https://example.com/public")!, snippet: snippet)]))
        return execution.id
    }
    func testUnrelatedExamAdministrationIsNotInjectedIntoMathRewrite() async throws {
        let service = ToolExecutionService(modelContainer: try AgentTestFixtures.container()), conversation = UUID()
        let id = try await saved(service, conversation: conversation, query: "考研数学一报名时间", title: "考研数学一考试时间与报名流程", snippet: "研招报名流程和考试时间安排")
        let legacy = await service.contextForChat(conversationID: conversation)
        XCTAssertEqual(legacy?.executions.count, 1)
        let filtered = await service.contextForChat(conversationID: conversation,
            currentUserText: "如果把这道题改成考研数学一的试题，会怎么改？", previousUserText: "考研报名时间")
        XCTAssertNil(filtered)
        let record = try await service.store.execution(id: id)
        XCTAssertEqual(record?.status, .succeeded, "Relevance must not delete or invalidate audit evidence")
    }
    func testRelevantOlderEvidenceSurvivesUnrelatedRecentResultsAndScope() async throws {
        let service = ToolExecutionService(modelContainer: try AgentTestFixtures.container()), conversation = UUID()
        let relevantID = try await saved(service, conversation: conversation, query: "骰子点数 古典概型 概率计算", title: "古典概型与骰子点数", snippet: "用隔板法计算骰子点数之和")
        for i in 0..<3 { _ = try await saved(service, conversation: conversation, query: "报名时间\(i)", title: "研招流程", snippet: "报名公告") }
        _ = try await saved(service, conversation: UUID(), query: "骰子点数", title: "foreign secret fixture", snippet: "other conversation")
        let selected = await service.contextForChat(conversationID: conversation, currentUserText: "解释骰子点数之和的古典概型计算方法")
        XCTAssertEqual(selected?.executions.map(\.executionID), [relevantID])
        XCTAssertFalse(selected?.messageContent.contains("foreign secret") == true)
        let excluded = await service.contextForChat(conversationID: conversation, excludingIDs: [relevantID], currentUserText: "解释骰子点数之和的古典概型计算方法")
        XCTAssertNil(excluded)
    }
    func testExplicitRecallFollowupAndNegativeReferences() async throws {
        let service = ToolExecutionService(modelContainer: try AgentTestFixtures.container()), conversation = UUID()
        _ = try await saved(service, conversation: conversation, query: "DeepSeek API update", title: "DeepSeek update", snippet: "Public fixture version 4.2")
        for text in ["你刚才搜索了吗？", "根据这些来源继续总结", "Did you search?", "DeepSeek 的接口说明是什么？"] {
            let result = await service.contextForChat(conversationID: conversation, currentUserText: text)
            XCTAssertEqual(result?.executions.count, 1, text)
            XCTAssertTrue(result?.messageContent.contains("not the CURRENT TURN") == true)
        }
        let followup = await service.contextForChat(conversationID: conversation, currentUserText: "那为什么？", previousUserText: "DeepSeek API update")
        XCTAssertEqual(followup?.executions.count, 1)
        let unrelated = await service.contextForChat(conversationID: conversation, currentUserText: "把它改成英文", previousUserText: "DeepSeek API update")
        XCTAssertNil(unrelated)
        let forbidden = await service.contextForChat(conversationID: conversation, currentUserText: "不要参考之前的 DeepSeek 搜索")
        XCTAssertNil(forbidden)
        let empty = await service.contextForChat(conversationID: conversation, currentUserText: "")
        XCTAssertNil(empty)
    }
    func testCounterMatchesSwiftCountAtEveryUnicodeBoundary() {
        let examples = ["数学思考过程🧮", "e\u{301}\r\n你好", "👩🏽‍💻👨‍👩‍👧‍👦🇨🇳🇺🇸🇯🇵", "क्\u{200d}षक्ष", "a\u{301}\u{302}\u{303}", "\r\n\r\n"]
        for text in examples {
            var prefix = "", counter = StreamingCharacterCount()
            for scalar in text.unicodeScalars {
                let fragment = String(scalar); prefix += fragment; counter.append(fragment)
                XCTAssertEqual(counter.count, prefix.count, prefix)
                counter.append(""); XCTAssertEqual(counter.count, prefix.count)
            }
        }
        // Different segmentation, including large CJK chunks and ASCII punctuation.
        for width in 1...8 {
            let scalars = Array(examples.joined(separator: "\n").unicodeScalars)
            var prefix = "", counter = StreamingCharacterCount()
            for start in stride(from: 0, to: scalars.count, by: width) {
                let fragment = scalars[start..<min(scalars.count, start + width)].map(String.init).joined()
                prefix += fragment; counter.append(fragment); XCTAssertEqual(counter.count, prefix.count)
            }
        }
    }
    func testChineseStreamingCounterWorkAndMeasuredComparison() throws {
        let chunks = Array(repeating: "数学思考过程", count: 2000)
        let clock = ContinuousClock()
        var full = "", baselineCount = 0, oldScanned = 0
        let oldStart = clock.now
        for chunk in chunks { full += chunk; baselineCount = full.count; oldScanned += full.utf8.count }
        let oldDuration = oldStart.duration(to: clock.now)
        var counter = StreamingCharacterCount()
        let newStart = clock.now
        for chunk in chunks { counter.append(chunk) }
        let newDuration = newStart.duration(to: clock.now)
        XCTAssertEqual(counter.count, baselineCount)
        XCTAssertLessThan(counter.scannedUTF8Bytes * 100, oldScanned)
        // Timing is evidence, not a fragile CI speed-ratio assertion.
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let report: [String: Double] = ["chunks": Double(chunks.count), "characters": Double(baselineCount), "old_ms": ms(oldDuration), "new_ms": ms(newDuration), "old_scanned_utf8": Double(oldScanned), "new_scanned_utf8": Double(counter.scannedUTF8Bytes)]
        print("[StreamingCountBenchmark] " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
    }
    func testAgentPreservesSeparateCountersAndOutputBudget() async throws {
        for limit in [2, 3] {
            var budget = AgentLoopBudget.production; budget.maxRoundOutputCharacters = limit
            let deltas: [StreamDelta] = [.reasoning("e"), .reasoning("\u{301}"), .content("好"), .content("的"), .finishReason("stop"), .done]
            let runner = AgentRunner(model: ScriptedAgentModel(rounds: [deltas]), executor: FixtureAgentExecutor(), persistence: ToolExecutionService(modelContainer: try AgentTestFixtures.container()))
            do {
                let events = try await AgentTestFixtures.collect(runner.events(for: AgentTestFixtures.request(tools: [], budget: budget)))
                XCTAssertEqual(limit, 3)
                XCTAssertTrue(events.contains { if case .finalAnswer(let text, let reasoning, _) = $0 { return text == "好的" && reasoning == "e\u{301}" }; return false })
            } catch { XCTAssertEqual(limit, 2); XCTAssertEqual(error as? AgentError, .budgetExceeded) }
        }
    }
    func testLongReasoningAndNativeToolReentryRemainExact() async throws {
        let text = String(repeating: "数学思考过程", count: 2000)
        var first = Array(repeating: StreamDelta.reasoning("数学思考过程"), count: 2000)
        first += [.toolCall(.init(index: 0, id: "count_call", type: "function", name: "web_search", arguments: "{\"query\":\"fixture\",\"limit\":1}")), .finishReason("tool_calls"), .done]
        let model = ScriptedAgentModel(rounds: [first, AgentTestFixtures.finalRound])
        let service = ToolExecutionService(modelContainer: try AgentTestFixtures.container())
        _ = try await AgentTestFixtures.collect(AgentRunner(model: model, executor: FixtureAgentExecutor(), persistence: service).events(for: AgentTestFixtures.request()))
        let requests = await model.captured()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].messages.first { $0.role == "assistant" }?.reasoningContent, text)
        XCTAssertEqual(requests[1].messages.last?.toolCallID, "count_call")
    }
}
