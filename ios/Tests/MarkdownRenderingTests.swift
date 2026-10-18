import XCTest
import WebKit
@testable import PersonalDeepSeek

@MainActor private final class MarkdownLoader: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let ready = XCTestExpectation(description: "bundled Markdown page loaded")
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready.fulfill() }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { }
}

@MainActor final class MarkdownRenderingTests: XCTestCase {
    private func page() async throws -> WKWebView {
        let loader = MarkdownLoader(), configuration = WKWebViewConfiguration()
        configuration.userContentController.add(loader, name: "contentHeight")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        web.navigationDelegate = loader
        web.loadHTMLString(MathMarkdownWebView.template, baseURL: Bundle.main.resourceURL)
        await fulfillment(of: [loader.ready], timeout: 30)
        return web
    }
    private func js(_ code: String, in web: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(code) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result as? String ?? "") }
            }
        }
    }
    private func render(_ markdown: String, in web: WKWebView) async throws {
        let encoded = Data(markdown.utf8).base64EncodedString()
        _ = try await js("window.__renderDone=false;window.__renderError='';renderMarkdown('\(encoded)').then(()=>window.__renderDone=true).catch(e=>{window.__renderError=String(e);window.__renderDone=true}); 'queued'", in: web)
        for _ in 0..<400 {
            let done = try await js("String(window.__renderDone)", in: web)
            if done == "true" {
                let error = try await js("window.__renderError", in: web)
                XCTAssertEqual(error, ""); return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Bundled Markdown/MathJax rendering did not finish")
    }
    func testActualBundledRendererSupportsQuotesMathTablesAndCode() async throws {
        let web = try await page()
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers() }
        let source = "> **例1**\n>\n> $$P(S\\le10)=\\frac{5}{11664}$$\n\n|A|B|\n|-|-|\n|1|2|\n\n```swift\nlet x = a < b\n```\n\n[来源](https://example.com/source)"
        try await render(source, in: web)
        let result = try await js("JSON.stringify({quote:document.querySelectorAll('#content blockquote').length,math:document.querySelectorAll('blockquote mjx-container').length,table:document.querySelectorAll('table').length,code:document.querySelector('pre code')?.textContent,link:document.querySelector('a')?.getAttribute('href')})", in: web)
        let data = try XCTUnwrap(result.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["quote"] as? Int, 1); XCTAssertEqual(object["math"] as? Int, 1)
        XCTAssertEqual(object["table"] as? Int, 1); XCTAssertTrue((object["code"] as? String)?.contains("a < b") == true)
        XCTAssertEqual(object["link"] as? String, "https://example.com/source")
    }
    func testRawHTMLAndUnsafeLinksRemainInert() async throws {
        let web = try await page()
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers() }
        let source = "> 正常引用\n\n<script>window.__attackFired=true</script>\n\n<img src=x onerror=\"window.__attackFired=true\">\n\n[危险](javascript:alert(1))\n\n[文件](file:///private/test)\n\n[正常](https://example.com/safe)\n\n`<b>code</b>`"
        try await render(source, in: web)
        let result = try await js("JSON.stringify({attack:window.__attackFired===true,scripts:document.querySelectorAll('#content script').length,events:document.querySelectorAll('#content [onerror],#content [onclick]').length,bad:Array.from(document.querySelectorAll('#content a')).some(a=>/^(javascript|data|file|vbscript):/i.test(a.getAttribute('href')||'')),quote:document.querySelectorAll('blockquote').length,code:document.querySelector('code')?.textContent})", in: web)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(object["attack"] as? Bool, false); XCTAssertEqual(object["scripts"] as? Int, 0)
        XCTAssertEqual(object["events"] as? Int, 0); XCTAssertEqual(object["bad"] as? Bool, false)
        XCTAssertEqual(object["quote"] as? Int, 1); XCTAssertEqual(object["code"] as? String, "<b>code</b>")
    }
    func testMathJaxGeneratedLinksAreAlsoFiltered() async throws {
        let web = try await page()
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers() }
        try await render("$$\\href{javascript:alert(1)}{x}$$\n\n> 引用", in: web)
        let result = try await js("String(Array.from(document.querySelectorAll('#content a')).some(a=>/javascript:/i.test((a.getAttribute('href')||'')+(a.getAttribute('xlink:href')||''))))", in: web)
        XCTAssertEqual(result, "false")
    }
}
