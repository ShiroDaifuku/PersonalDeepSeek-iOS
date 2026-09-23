import XCTest
@testable import PersonalDeepSeek

final class MessagePrefixTests: XCTestCase {
    func testStableSystemHistoryAndNewMessageOrder() {
        let conversation = Conversation(); let a = ChatMessage(role: "user", content: "one", conversation: conversation); let b = ChatMessage(role: "assistant", content: "two", conversation: conversation)
        a.createdAt = Date(timeIntervalSince1970: 1); b.createdAt = Date(timeIntervalSince1970: 2)
        XCTAssertEqual(MessagePrefix.stable(system: "system", history: [b, a], newUserText: "three"), [APIMessage(role: "system", content: "system"), APIMessage(role: "user", content: "one"), APIMessage(role: "assistant", content: "two"), APIMessage(role: "user", content: "three")])
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
}
