import XCTest
@testable import PersonalDeepSeek

final class LocalResearchTests: XCTestCase {
    func testRejectsPrivateAndNonHTTPSSources() {
        XCTAssertFalse(LocalResearchService.isAllowed(URL(string: "http://example.com")!))
        XCTAssertFalse(LocalResearchService.isAllowed(URL(string: "https://127.0.0.1/private")!))
        XCTAssertFalse(LocalResearchService.isAllowed(URL(string: "https://router.local/")!))
        XCTAssertTrue(LocalResearchService.isAllowed(URL(string: "https://example.com/article")!))
    }

    func testHTMLExtractionDropsScriptsAndTags() {
        let text = LocalResearchService.plainText(fromHTML: "<style>x{}</style><h1>Hello &amp; 世界</h1><script>bad()</script><p>Body</p>")
        XCTAssertEqual(text, "Hello & 世界 Body")
    }

    func testEvidenceUsesStableNumberedCitations() {
        let source = ResearchSource(title: "Example", url: URL(string: "https://example.com")!, snippet: "Snippet", pageText: "Body")
        let prompt = LocalResearchService.evidencePrompt(question: "Question", sources: [source])
        XCTAssertTrue(prompt.contains("[1] Example"))
        XCTAssertTrue(prompt.contains("https://example.com"))
    }

    func testParsesBingRSSFallback() {
        let xml = """
        <?xml version="1.0"?><rss><channel><item><title>示例结果</title><link>https://example.com/article</link><description>&lt;b&gt;摘要&lt;/b&gt;</description></item></channel></rss>
        """
        let rows = LocalResearchService.parseBingRSS(Data(xml.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "示例结果")
        XCTAssertEqual(rows.first?.link, "https://example.com/article")
        XCTAssertTrue(rows.first?.description.contains("摘要") == true)
    }
}
