import Foundation
import XCTest
@testable import PersonalDeepSeek

private enum ResearchTestError: Error, Sendable {
    case dns
    case network
}

private struct MockDNSResolver: ResearchDNSResolving {
    let records: [String: [String]]
    let failingHosts: Set<String>

    init(records: [String: [String]] = [:], failingHosts: Set<String> = []) {
        self.records = records
        self.failingHosts = failingHosts
    }

    func addresses(for host: String) async throws -> [String] {
        if failingHosts.contains(host) { throw ResearchTestError.dns }
        guard let addresses = records[host] else { throw ResearchTestError.dns }
        return addresses
    }
}

private struct ClosureHTTPFetcher: ResearchHTTPFetching {
    let handler: @Sendable (URLRequest) async throws -> ResearchHTTPResponse

    func data(for request: URLRequest) async throws -> ResearchHTTPResponse {
        try await handler(request)
    }
}

private actor FetchProbe {
    private var active = 0
    private var maximumActive = 0
    private var completionOrder: [String] = []

    func begin() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func finish(_ path: String) {
        active -= 1
        completionOrder.append(path)
    }

    func snapshot() -> (Int, [String]) { (maximumActive, completionOrder) }
}

private final class RedirectDecisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    func record(_ request: URLRequest?) { lock.withLock { storedRequest = request } }
    func value() -> URLRequest? { lock.withLock { storedRequest } }
}

final class LocalResearchTests: XCTestCase {
    private static let publicIP = "93.184.216.34"

    func testURLShapeAndLiteralAddressPolicy() {
        let allowed = [
            "https://example.com/article",
            "https://example.com:8443/article",
            "https://93.184.216.34/article",
            "https://[2606:4700:4700::1111]/article"
        ]
        let rejected = [
            "http://example.com",
            "file:///etc/passwd",
            "https://localhost/private",
            "https://localhost./private",
            "https://router.local/private",
            "https://127.1.2.3/private",
            "https://10.0.0.1/private",
            "https://172.16.0.1/private",
            "https://172.31.255.255/private",
            "https://192.168.1.1/private",
            "https://169.254.169.254/latest/meta-data",
            "https://100.64.0.1/private",
            "https://[::1]/private",
            "https://[fe80::1]/private",
            "https://[fc00::1]/private",
            "https://[fd00::1]/private",
            "https://[::ffff:192.168.1.1]/private"
        ]

        for rawURL in allowed {
            XCTAssertTrue(LocalResearchService.isAllowed(URL(string: rawURL)!), rawURL)
        }
        for rawURL in rejected {
            XCTAssertFalse(LocalResearchService.isAllowed(URL(string: rawURL)!), rawURL)
        }
    }

    func testDNSPolicyAllowsOnlyEntirelyPublicAnswers() async throws {
        let policy = ResearchURLPolicy(resolver: MockDNSResolver(records: [
            "public.example": [Self.publicIP, "2606:4700:4700::1111"],
            "private.example": ["10.0.0.1"],
            "mixed.example": [Self.publicIP, "192.168.1.2"]
        ]))

        let publicURL = URL(string: "https://public.example/article")!
        let validatedURL = try await policy.validate(publicURL)
        XCTAssertEqual(validatedURL, publicURL)
        await assertUnsafeURL(URL(string: "https://private.example/")!, policy: policy)
        await assertUnsafeURL(URL(string: "https://mixed.example/")!, policy: policy)
    }

    func testDNSFailureFailsClosed() async {
        let policy = ResearchURLPolicy(resolver: MockDNSResolver(failingHosts: ["broken.example"]))
        do {
            _ = try await policy.validate(URL(string: "https://broken.example/")!)
            XCTFail("A DNS failure must not allow the request")
        } catch ResearchTestError.dns {
            // Expected: no request is issued after resolution fails.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSystemDNSResolverTimeoutReturnsWithoutWaitingForBlockingLookup() async {
        let resolver = SystemResearchDNSResolver(timeout: 0.02) { _ in
            Thread.sleep(forTimeInterval: 0.25)
            return [Self.publicIP]
        }

        do {
            _ = try await resolver.addresses(for: "slow.example")
            XCTFail("The DNS timeout must finish first")
        } catch LocalResearchError.dnsResolutionTimedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSystemDNSResolverCancellationReturnsWithoutWaitingForBlockingLookup() async {
        let resolver = SystemResearchDNSResolver(timeout: 5) { _ in
            Thread.sleep(forTimeInterval: 0.25)
            return [Self.publicIP]
        }
        let task = Task { try await resolver.addresses(for: "slow.example") }

        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("DNS cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPublicToPublicRedirectIsFollowed() async throws {
        let resolver = MockDNSResolver(records: [
            "start.example": [Self.publicIP],
            "final.example": ["1.1.1.1"]
        ])
        let fetcher = ClosureHTTPFetcher { request in
            if request.url?.host == "start.example" {
                return Self.response(for: request, status: 302, headers: ["Location": "https://final.example/page"])
            }
            return Self.response(for: request, body: "<html><body>final body</body></html>")
        }
        let service = makeService(resolver: resolver, pageFetcher: fetcher)

        let result = try await service.fetch(Self.source("https://start.example/original"))

        XCTAssertEqual(result.url.absoluteString, "https://final.example/page")
        XCTAssertEqual(result.pageText, "final body")
    }

    func testRedirectToLocalhostIsRejectedBeforeSecondRequest() async {
        let resolver = MockDNSResolver(records: ["start.example": [Self.publicIP]])
        let fetcher = ClosureHTTPFetcher { request in
            Self.response(for: request, status: 302, headers: ["Location": "https://localhost/admin"])
        }
        let service = makeService(resolver: resolver, pageFetcher: fetcher)
        await assertUnsafeFetch(service, source: Self.source("https://start.example/"))
    }

    func testRedirectToPrivateIPv4IsRejected() async {
        let resolver = MockDNSResolver(records: ["start.example": [Self.publicIP]])
        let fetcher = ClosureHTTPFetcher { request in
            Self.response(for: request, status: 302, headers: ["Location": "https://192.168.1.50/admin"])
        }
        let service = makeService(resolver: resolver, pageFetcher: fetcher)
        await assertUnsafeFetch(service, source: Self.source("https://start.example/"))
    }

    func testRedirectToPrivateDNSAnswerIsRejected() async {
        let resolver = MockDNSResolver(records: [
            "start.example": [Self.publicIP],
            "internal.example": ["10.0.0.7"]
        ])
        let fetcher = ClosureHTTPFetcher { request in
            Self.response(for: request, status: 302, headers: ["Location": "https://internal.example/admin"])
        }
        let service = makeService(resolver: resolver, pageFetcher: fetcher)
        await assertUnsafeFetch(service, source: Self.source("https://start.example/"))
    }

    func testProductionRedirectDelegateRefusesAutomaticRedirect() {
        let delegate = ResearchNoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let originalURL = URL(string: "https://start.example/")!
        let redirectURL = URL(string: "https://127.0.0.1/admin")!
        let task = session.dataTask(with: originalURL)
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectURL.absoluteString]
        )!
        let decision = RedirectDecisionRecorder()

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectURL)
        ) { decision.record($0) }

        XCTAssertNil(decision.value())
    }

    func testExcessiveRedirectsAreRejected() async {
        let resolver = MockDNSResolver(records: ["loop.example": [Self.publicIP]])
        let fetcher = ClosureHTTPFetcher { request in
            Self.response(for: request, status: 302, headers: ["Location": "/again"])
        }
        let service = makeService(resolver: resolver, pageFetcher: fetcher)

        do {
            _ = try await service.fetch(Self.source("https://loop.example/start"))
            XCTFail("Redirect limit should be enforced")
        } catch LocalResearchError.tooManyRedirects {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHTMLResponseIsReadAndSanitized() async throws {
        let fetcher = ClosureHTTPFetcher { request in
            Self.response(
                for: request,
                body: "<style>x{}</style><h1>Hello &amp; 世界</h1><script>bad()</script><p>Body</p>"
            )
        }
        let service = makeService(pageFetcher: fetcher)

        let result = try await service.fetch(Self.source("https://example.com/article"))

        XCTAssertEqual(result.pageText, "Hello & 世界 Body")
    }

    func testUnsupportedMIMEIsRejected() async {
        let fetcher = ClosureHTTPFetcher { request in
            Self.response(for: request, data: Data([0x25, 0x50, 0x44, 0x46]), headers: ["Content-Type": "application/pdf"])
        }
        let service = makeService(pageFetcher: fetcher)

        do {
            _ = try await service.fetch(Self.source("https://example.com/file.pdf"))
            XCTFail("PDF content must not be parsed as a web page")
        } catch LocalResearchError.unsupportedContentType {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingMIMEBinaryBodyIsRejected() async {
        let fetcher = ClosureHTTPFetcher { request in
            Self.response(for: request, data: Data([0x00, 0x01, 0x02, 0x03]), headers: [:])
        }
        let service = makeService(pageFetcher: fetcher)

        do {
            _ = try await service.fetch(Self.source("https://example.com/binary"))
            XCTFail("Binary content without a MIME type must be rejected")
        } catch LocalResearchError.unsupportedContentType {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOversizedResponseIsRejected() async {
        let data = Data(repeating: 0x41, count: LocalResearchService.maximumPageBytes + 1)
        let fetcher = ClosureHTTPFetcher { request in
            Self.response(for: request, data: data)
        }
        let service = makeService(pageFetcher: fetcher)

        do {
            _ = try await service.fetch(Self.source("https://example.com/large"))
            XCTFail("Oversized content must be rejected")
        } catch LocalResearchError.pageTooLarge {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBraveFailureFallsBackToBing() async throws {
        let fetcher = ClosureHTTPFetcher { request in
            if request.url?.host == "api.search.brave.com" {
                return Self.response(for: request, status: 503)
            }
            return Self.response(for: request, data: Self.bingRSS([
                ("Fallback", "https://example.com/fallback", "RSS result")
            ]), headers: ["Content-Type": "application/rss+xml"])
        }
        let service = LocalResearchService(
            resolver: MockDNSResolver(),
            searchFetcher: fetcher,
            pageFetcher: fetcher,
            searchAPIKey: { "test-key" }
        )

        let rows = try await service.search(query: "query", limit: 3)

        XCTAssertEqual(rows.map(\.title), ["Fallback"])
    }

    func testSearchCancellationPropagates() async {
        let fetcher = ClosureHTTPFetcher { request in
            try await Task.sleep(for: .seconds(5))
            return Self.response(for: request, status: 500)
        }
        let service = LocalResearchService(
            resolver: MockDNSResolver(),
            searchFetcher: fetcher,
            pageFetcher: fetcher,
            searchAPIKey: { "test-key" }
        )
        let task = Task { try await service.search(query: "query", limit: 1) }

        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Search cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGatherFetchesConcurrentlyButPreservesSearchOrder() async throws {
        let probe = FetchProbe()
        let searchFetcher = Self.searchFetcher([
            ("Slow", "https://slow.example/article", "slow snippet"),
            ("Fast", "https://fast.example/article", "fast snippet")
        ])
        let pageFetcher = ClosureHTTPFetcher { request in
            let host = request.url!.host!
            await probe.begin()
            if host == "slow.example" {
                try await Task.sleep(for: .milliseconds(120))
            } else {
                try await Task.sleep(for: .milliseconds(20))
            }
            await probe.finish(host)
            return Self.response(for: request, body: "\(host) body")
        }
        let resolver = MockDNSResolver(records: [
            "slow.example": [Self.publicIP],
            "fast.example": ["1.1.1.1"]
        ])
        let service = makeService(resolver: resolver, searchFetcher: searchFetcher, pageFetcher: pageFetcher)

        let rows = try await service.gather(query: "query", limit: 2)
        let snapshot = await probe.snapshot()

        XCTAssertEqual(rows.map(\.title), ["Slow", "Fast"])
        XCTAssertEqual(snapshot.0, 2)
        XCTAssertEqual(snapshot.1.first, "fast.example")
    }

    func testSinglePageFailureFallsBackToSearchSnippet() async throws {
        let searchFetcher = Self.searchFetcher([
            ("Good", "https://good.example/article", "good snippet"),
            ("Broken", "https://broken.example/article", "kept snippet")
        ])
        let pageFetcher = ClosureHTTPFetcher { request in
            if request.url?.host == "broken.example" { throw ResearchTestError.network }
            return Self.response(for: request, body: "full page")
        }
        let resolver = MockDNSResolver(records: [
            "good.example": [Self.publicIP],
            "broken.example": ["1.1.1.1"]
        ])
        let service = makeService(resolver: resolver, searchFetcher: searchFetcher, pageFetcher: pageFetcher)

        let rows = try await service.gather(query: "query", limit: 2)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].pageText, "full page")
        XCTAssertEqual(rows[1].snippet, "kept snippet")
        XCTAssertEqual(rows[1].pageText, "")
    }

    func testGatherCancellationPropagates() async {
        let searchFetcher = Self.searchFetcher([
            ("Slow", "https://slow.example/article", "snippet")
        ])
        let pageFetcher = ClosureHTTPFetcher { request in
            try await Task.sleep(for: .seconds(5))
            return Self.response(for: request, body: "too late")
        }
        let resolver = MockDNSResolver(records: ["slow.example": [Self.publicIP]])
        let service = makeService(resolver: resolver, searchFetcher: searchFetcher, pageFetcher: pageFetcher)
        let task = Task { try await service.gather(query: "query", limit: 1) }

        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate out of gather")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRealPublicNetworkingSmokeWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_RESEARCH_NETWORK_SMOKE"] == "1" else {
            throw XCTSkip("Set RUN_RESEARCH_NETWORK_SMOKE=1 for the Apple networking smoke test")
        }
        let service = LocalResearchService(searchAPIKey: { nil })

        let html = try await service.fetch(Self.source("https://example.com/"))
        XCTAssertFalse(html.pageText.isEmpty)

        let redirected = try await service.fetch(Self.source("https://apple.com/"))
        XCTAssertEqual(redirected.url.host, "www.apple.com")
        XCTAssertFalse(redirected.pageText.isEmpty)

        let searchRows = try await service.search(query: "Apple Swift concurrency", limit: 2)
        XCTAssertFalse(searchRows.isEmpty)
    }

    func testEvidenceUsesStableNumberedCitations() {
        let sources = [
            ResearchSource(title: "One", url: URL(string: "https://example.com/1")!, snippet: "A", pageText: "Body A"),
            ResearchSource(title: "Two", url: URL(string: "https://example.com/2")!, snippet: "B", pageText: "Body B")
        ]
        let prompt = LocalResearchService.evidencePrompt(question: "Question", sources: sources)

        XCTAssertTrue(prompt.contains("[1] One"))
        XCTAssertTrue(prompt.contains("[2] Two"))
        XCTAssertLessThan(prompt.range(of: "[1] One")!.lowerBound, prompt.range(of: "[2] Two")!.lowerBound)
    }

    func testParsesBingRSSFallback() {
        let rows = LocalResearchService.parseBingRSS(Self.bingRSS([
            ("示例结果", "https://example.com/article", "<b>摘要</b>")
        ]))

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "示例结果")
        XCTAssertEqual(rows.first?.link, "https://example.com/article")
        XCTAssertTrue(rows.first?.description.contains("摘要") == true)
    }

    private func assertUnsafeURL(_ url: URL, policy: ResearchURLPolicy) async {
        do {
            _ = try await policy.validate(url)
            XCTFail("Expected unsafe URL: \(url)")
        } catch LocalResearchError.unsafeURL {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertUnsafeFetch(_ service: LocalResearchService, source: ResearchSource) async {
        do {
            _ = try await service.fetch(source)
            XCTFail("Expected unsafe redirect")
        } catch LocalResearchError.unsafeURL {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeService(
        resolver: (any ResearchDNSResolving)? = nil,
        searchFetcher: (any ResearchHTTPFetching)? = nil,
        pageFetcher: any ResearchHTTPFetching
    ) -> LocalResearchService {
        LocalResearchService(
            resolver: resolver ?? MockDNSResolver(records: ["example.com": [Self.publicIP]]),
            searchFetcher: searchFetcher ?? pageFetcher,
            pageFetcher: pageFetcher,
            searchAPIKey: { nil }
        )
    }

    private static func source(_ rawURL: String) -> ResearchSource {
        ResearchSource(title: "Source", url: URL(string: rawURL)!, snippet: "Snippet")
    }

    private static func response(
        for request: URLRequest,
        status: Int = 200,
        body: String,
        headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"]
    ) -> ResearchHTTPResponse {
        response(for: request, status: status, data: Data(body.utf8), headers: headers)
    }

    private static func response(
        for request: URLRequest,
        status: Int = 200,
        data: Data = Data(),
        headers: [String: String] = [:]
    ) -> ResearchHTTPResponse {
        ResearchHTTPResponse(data: data, url: request.url!, statusCode: status, headers: headers)
    }

    private static func searchFetcher(_ rows: [(String, String, String)]) -> ClosureHTTPFetcher {
        let data = bingRSS(rows)
        return ClosureHTTPFetcher { request in
            response(for: request, data: data, headers: ["Content-Type": "application/rss+xml"])
        }
    }

    private static func bingRSS(_ rows: [(String, String, String)]) -> Data {
        let items = rows.map { title, link, description in
            "<item><title>\(xmlEscaped(title))</title><link>\(xmlEscaped(link))</link><description>\(xmlEscaped(description))</description></item>"
        }.joined()
        return Data("<?xml version=\"1.0\"?><rss><channel>\(items)</channel></rss>".utf8)
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
