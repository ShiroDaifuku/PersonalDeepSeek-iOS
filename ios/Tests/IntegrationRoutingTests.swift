import Foundation
import XCTest
@testable import PersonalDeepSeek

final class IntegrationRoutingTests: XCTestCase {
    func testFourRoutesRemainDistinct() {
        XCTAssertEqual(AssistantIntentRouter.preferredTool(for: "深度研究 DeepSeek API"), "start_deep_search")
        XCTAssertEqual(AssistantIntentRouter.preferredTool(for: "今天 DeepSeek API 有什么更新？"), "web_search")
        XCTAssertEqual(AssistantIntentRouter.preferredTool(for: "联网查一下 DeepSeek API"), "web_search")
        XCTAssertNil(AssistantIntentRouter.preferredTool(for: "矩阵的秩是什么？"))
        XCTAssertEqual(AssistantIntentRouter.preferredTool(for: "明天提醒我洗衣服"), "create_scheduled_task")
    }

    func testResearchEvidenceOccursOnceWithoutNativeToolReply() throws {
        let marker = "UNIQUE_RESEARCH_EVIDENCE_78214"
        let source = ResearchSource(title: "Fixture", url: URL(string: "https://example.com/research")!,
            snippet: marker, pageText: "The verified page contains \(marker).")
        let request = try ChatRequestAssembler.researchMessages(system: "Conversation only", history: [],
            researchQuestion: "What happened?", researchSources: [source], memoryContext: nil,
            newUserText: "深度研究这个问题")
        let evidenceMessages = request.messages.filter { $0.content.contains("Web research evidence:") }
        XCTAssertEqual(evidenceMessages.count, 1)
        XCTAssertEqual(request.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertFalse(request.messages.contains { $0.role == "tool" })
        XCTAssertTrue(evidenceMessages[0].content.contains(marker))
    }

    func testNativeRequestPreservesToolProtocolAndAppliesImageGuards() throws {
        let call = NativeToolCall(id: "tool-1", type: "function",
            function: .init(name: "web_search", arguments: #"{"query":"fixture","limit":1}"#))
        let transcript: [APIMessage] = [
            .init(role: "user", content: "Search"),
            .init(role: "assistant", content: "", reasoningContent: "reasoned", toolCalls: [call]),
            .init(role: "tool", content: "{}", toolCallID: "tool-1")
        ]
        let body = try APIClient.requestBody(.init(messages: transcript, model: "deepseek-flash",
            thinking: true, reasoningEffort: "low", toolNames: ["web_search"], toolChoice: .auto))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wire = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(wire[1]["reasoning_content"] as? String, "reasoned")
        XCTAssertEqual(wire[2]["tool_call_id"] as? String, "tool-1")
        XCTAssertNotNil(wire[1]["tool_calls"])

        let image = "data:image/jpeg;base64,YQ=="
        XCTAssertThrowsError(try APIClient.requestBody(.init(messages: [
            .init(role: "user", content: "Look", imageDataURLs: Array(repeating: image, count: 7))
        ], model: "deepseek-flash", thinking: false, reasoningEffort: "none")))
        XCTAssertThrowsError(try APIClient.requestBody(.init(messages: [
            .init(role: "user", content: "Look", imageDataURLs: [image])
        ], model: "deepseek-v4-pro", thinking: false, reasoningEffort: "none")))
    }
}
