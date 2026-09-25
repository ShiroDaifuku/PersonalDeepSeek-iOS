import XCTest
@testable import PersonalDeepSeek

final class MessagePrefixTests: XCTestCase {
    func testStableSystemHistoryAndNewMessageOrder() {
        let conversation = Conversation(); let a = ChatMessage(role: "user", content: "one", conversation: conversation); let b = ChatMessage(role: "assistant", content: "two", conversation: conversation)
        a.createdAt = Date(timeIntervalSince1970: 1); b.createdAt = Date(timeIntervalSince1970: 2)
        let messages = MessagePrefix.stable(system: "system", history: [b, a], newUserText: "three")
        XCTAssertTrue(messages[0].content.hasPrefix("system"))
        XCTAssertTrue(messages[0].content.contains("LaTeX"))
        XCTAssertEqual(Array(messages.dropFirst()), [APIMessage(role: "user", content: "one"), APIMessage(role: "assistant", content: "two"), APIMessage(role: "user", content: "three")])
    }

    func testImageMessageUsesMultimodalWireParts() throws {
        let message = APIMessage(role: "user", content: "look", imageDataURLs: ["data:image/jpeg;base64,YQ=="])
        let parts = try XCTUnwrap(message.wireContent as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "look")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        XCTAssertEqual((parts[1]["image_url"] as? [String: String])?["url"], "data:image/jpeg;base64,YQ==")
    }

    func testPlainMessageKeepsStringWireFormat() {
        XCTAssertEqual(APIMessage(role: "user", content: "hello").wireContent as? String, "hello")
    }

    func testKnowledgeContextDoesNotChangeStableSystemHistoryPrefix() {
        let conversation = Conversation()
        let history = ChatMessage(role: "assistant", content: "earlier", conversation: conversation)
        let messages = MessagePrefix.stable(system: "system", history: [history], knowledgeContext: "[1] note\nlocal text", newUserText: "question")
        XCTAssertTrue(messages[0].content.hasPrefix("system"))
        XCTAssertEqual(messages[1], APIMessage(role: "assistant", content: "earlier"))
        XCTAssertEqual(messages[2].role, "system")
        XCTAssertTrue(messages[2].content.contains("local text"))
        XCTAssertEqual(messages[3], APIMessage(role: "user", content: "question"))
    }

    func testToolContextSaysItWasExecutedForCurrentRequest() {
        let messages = MessagePrefix.stable(system: "system", history: [], knowledgeContext: "Web research evidence", newUserText: "question")
        XCTAssertTrue(messages[1].content.contains("successfully executed"))
        XCTAssertTrue(messages[1].content.contains("Do not say that you cannot access"))
    }

    func testStreamingPreviewIsBoundedToRecentText() {
        XCTAssertEqual(StreamingTextBuffer.visibleTail("abcdef", limit: 4), "…cdef")
        XCTAssertEqual(StreamingTextBuffer.visibleTail("abc", limit: 4), "abc")
        XCTAssertEqual(StreamingTextBuffer.visibleTail("abc", limit: 0), "")
    }
}
