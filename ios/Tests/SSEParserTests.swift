import XCTest
@testable import PersonalDeepSeek

final class SSEParserTests: XCTestCase {
    func testFragmentedCRLFKeepAliveReasoningContentUsageDone() {
        var parser = SSEParser(); var result: [StreamDelta] = []
        result += parser.append(Data(": keep-alive\r\n\r\nda".utf8))
        result += parser.append(Data("ta: {\"choices\":[{\"delta\":{\"reasoning_content\":\"想\"}}]}\r\n\r\n".utf8))
        result += parser.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"答案\"}}],\"usage\":{\"total_tokens\":9}}\n\ndata: [DONE]\n\n".utf8))
        XCTAssertEqual(result, [.reasoning("想"), .content("答案"), .usage(9), .done])
    }

    func testUTF8SplitInsideMultibyteScalar() {
        var parser = SSEParser()
        let bytes = Array("data: {\"choices\":[{\"delta\":{\"content\":\"中文\"}}]}\n\n".utf8)
        let split = bytes.firstIndex(of: 0xE4)!
        XCTAssertEqual(parser.append(Data(bytes[0...split])), [])
        XCTAssertEqual(parser.append(Data(bytes[(split + 1)...])), [.content("中文")])
    }

    func testLineBasedParsingHandlesKeepAliveAndBlankDelimiter() {
        var parser = SSEParser()
        XCTAssertEqual(parser.appendLine(": keep-alive"), [])
        XCTAssertEqual(parser.appendLine(""), [])
        XCTAssertEqual(parser.appendLine(#"data: {"choices":[{"delta":{"reasoning_content":"分析"}}]}"#), [])
        XCTAssertEqual(parser.appendLine(""), [.reasoning("分析")])
        XCTAssertEqual(parser.appendLine("data: [DONE]"), [])
        XCTAssertEqual(parser.appendLine(""), [.done])
    }
}
