import Foundation
import UIKit
import XCTest
@testable import PersonalDeepSeek

private struct ClientWebHTTP: ResearchHTTPFetching {
    let handler: @Sendable (URLRequest) async throws -> ResearchHTTPResponse
    func data(for request: URLRequest) async throws -> ResearchHTTPResponse { try await handler(request) }
}
private actor ClientRequestLog {
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
    func all() -> [URLRequest] { requests }
}

final class ClientWebServiceTests: XCTestCase {
    func testOfficialSearchFetchSchemaAndIndependentKey() async throws {
        let log = ClientRequestLog()
        let fetcher = ClientWebHTTP { request in
            await log.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dedicated-web-fixture")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "api.deepseek.com")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let payload: String
            if request.url?.path == "/v1/tools/search" {
                XCTAssertEqual(body["query"] as? String, "public query")
                XCTAssertEqual(body["count"] as? Int, 3)
                XCTAssertEqual(body["need_content"] as? Bool, false)
                payload = #"{"results":[{"title":"Official","url":"https://example.com/public","snippet":"short","summary":"long summary","content":"","rerank_score":2.4}]}"#
            } else {
                XCTAssertEqual(request.url?.path, "/v1/tools/fetch")
                XCTAssertEqual(body["url"] as? String, "https://example.com/public")
                payload = #"{"title":"Page","content":"# Verified public content"}"#
            }
            return .init(data: Data(payload.utf8), url: request.url!, statusCode: 200)
        }
        let result = try await DeepSeekWebService(key: { "dedicated-web-fixture" }, fetcher: fetcher).gather(query: "public query", limit: 9)
        XCTAssertEqual(result.providerUsed, .deepSeek)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources[0].snippet, "long summary")
        XCTAssertEqual(result.sources[0].pageText, "# Verified public content")
        let requests = await log.all(); XCTAssertEqual(requests.count, 2)
    }

    func testMissingKeyAndOversizeQueryDoNotSendHTTP() async {
        let fetcher = ClientWebHTTP { _ in XCTFail("No HTTP expected"); throw URLError(.badURL) }
        do { _ = try await DeepSeekWebService(key: { nil }, fetcher: fetcher).search(query: "test"); XCTFail() }
        catch { XCTAssertEqual(error as? DeepSeekWebError, .missingKey) }
        do { _ = try await DeepSeekWebService(key: { "fixture" }, fetcher: fetcher).search(query: String(repeating: "字", count: 129)); XCTFail() }
        catch { XCTAssertEqual(error as? DeepSeekWebError, .invalidQuery) }
    }

    func testAuthenticationFailureIsNotHiddenByProviderFallback() async {
        let log = ClientRequestLog()
        let fetcher = ClientWebHTTP { request in
            await log.append(request)
            return .init(data: Data("{}".utf8), url: request.url!, statusCode: 401)
        }
        do { _ = try await DeepSeekWebService(key: { "invalid-fixture" }, fetcher: fetcher).gather(query: "public"); XCTFail() }
        catch { XCTAssertEqual(error as? DeepSeekWebError, .http(401)) }
        let count = await log.all().count; XCTAssertEqual(count, 1)
    }

    func testEmptySearchDoesNotFetchPages() async throws {
        let log = ClientRequestLog()
        let fetcher = ClientWebHTTP { request in
            await log.append(request)
            return .init(data: Data(#"{"results":[]}"#.utf8), url: request.url!, statusCode: 200)
        }
        let result = try await DeepSeekWebService(key: { "fixture" }, fetcher: fetcher).gather(query: "unmatched")
        XCTAssertTrue(result.sources.isEmpty)
        let count = await log.all().count; XCTAssertEqual(count, 1)
    }

    func testInvalidSchemaAndUnsafeURLsAreRejected() async throws {
        let malformed = ClientWebHTTP { request in .init(data: Data("not json".utf8), url: request.url!, statusCode: 200) }
        do { _ = try await DeepSeekWebService(key: { "fixture" }, fetcher: malformed).search(query: "public"); XCTFail() }
        catch { XCTAssertEqual(error as? DeepSeekWebError, .invalidResponse) }
        let client = DeepSeekWebService(key: { "fixture" }, fetcher: malformed)
        for raw in ["https://127.0.0.1/", "https://user:password@example.com/", "http://example.com/"] {
            do { _ = try await client.fetch(.init(title: "unsafe", url: URL(string: raw)!, snippet: "")); XCTFail() }
            catch { XCTAssertEqual(error as? DeepSeekWebError, .invalidURL) }
        }
    }

    func test429UsesBoundedAttempts() async {
        let log = ClientRequestLog()
        let fetcher = ClientWebHTTP { request in
            await log.append(request)
            return .init(data: Data("{}".utf8), url: request.url!, statusCode: 429)
        }
        do { _ = try await DeepSeekWebService(key: { "fixture" }, fetcher: fetcher).search(query: "public"); XCTFail() }
        catch { XCTAssertEqual(error as? DeepSeekWebError, .http(429)) }
        let count = await log.all().count; XCTAssertEqual(count, 3)
    }

    func testCancelledRequestDoesNotRetryOrBecomeEmptySuccess() async {
        let fetcher = ClientWebHTTP { _ in throw CancellationError() }
        do { _ = try await DeepSeekWebService(key: { "fixture" }, fetcher: fetcher).gather(query: "public"); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCredentialsMaskingValidationAndDefaults() throws {
        XCTAssertEqual(ClientCredentials.masked(nil), "未设置")
        XCTAssertFalse(ClientCredentials.masked("sk-fixture-private-value").contains("private"))
        XCTAssertThrowsError(try ClientCredentials.validated(" \n "))
        XCTAssertThrowsError(try ClientCredentials.validated("key with spaces"))
        XCTAssertEqual(try ClientCredentials.validated("  fixture-key\n"), "fixture-key")
        let name = "ClientSettingsTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(ClientCredentials.webProvider(defaults: defaults), .deepSeek)
        XCTAssertTrue(ClientCredentials.reusesChatKey(defaults: defaults))
        defaults.set(false, forKey: ClientCredentials.reuseChatKeySetting)
        defaults.set("bing", forKey: ClientCredentials.webProviderSetting)
        XCTAssertFalse(ClientCredentials.reusesChatKey(defaults: defaults))
        XCTAssertEqual(ClientCredentials.webProvider(defaults: defaults), .bing)
    }
}

@MainActor final class ClientImageTests: XCTestCase {
    static func testImage() throws -> PendingAttachment {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 160))
        let image = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
            ("742" as NSString).draw(at: CGPoint(x: 15, y: 15), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 80), .foregroundColor: UIColor.black])
        }
        return try XCTUnwrap(PendingAttachment.image(data: XCTUnwrap(image.pngData())))
    }

    func testCameraOutputIsDecodableAndUpright() throws {
        let attachment = try Self.testImage()
        let decoded = try ChatImageUpload.decodedImage(attachment.dataURL)
        XCTAssertEqual(decoded.mime, "image/jpeg")
        let image = try XCTUnwrap(UIImage(data: decoded.data))
        XCTAssertEqual(image.imageOrientation, .up)
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 1600)
    }

    func testMalformedImageCannotBeUploadedAsText() {
        for value in ["data:image/jpeg;base64,YQ==", "data:image/jpeg;base64,", "https://example.com/image.jpg"] {
            XCTAssertThrowsError(try ChatImageUpload.decodedImage(value))
        }
    }

    func testMultipartHasOneHourExpiryAndActualImageBytes() throws {
        let attachment = try Self.testImage()
        let body = ChatImageUpload.multipart(data: attachment.data, mime: "image/jpeg", boundary: "fixture")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("expires_after[seconds]"))
        XCTAssertTrue(text.contains("3600"))
        XCTAssertTrue(text.contains("user_data"))
        XCTAssertNotNil(body.range(of: attachment.data))
        XCTAssertTrue(text.hasSuffix("--fixture--\r\n"))
    }

    func testUploadedFileReferenceReplacesInlineDataExactlyOnce() throws {
        let attachment = try Self.testImage()
        let request = AgentModelRequest(messages: [.init(role: "user", content: "look", imageDataURLs: [attachment.dataURL])],
            model: "deepseek-flash", thinking: true, reasoningEffort: "low", toolNames: [], toolChoice: .auto)
        let data = try APIClient.requestBody(request, uploadedImages: [attachment.dataURL: "file-api-fixture"])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1]["type"] as? String, "file")
        XCTAssertEqual(parts[1]["file_id"] as? String, "file-api-fixture")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("base64"))
        XCTAssertThrowsError(try APIClient.requestBody(request, uploadedImages: ["unrelated": "file-api-other"]))
    }

    func testOptInLiveCameraImageAndOfficialWeb() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RUN_CLIENT_MEDIA_WEB_EVALUATION"] == "1", "Opt-in public-image/API smoke only")
        let key = try XCTUnwrap(env["DEEPSEEK_API_KEY"])
        let attachment = try Self.testImage()
        var answer = ""
        for try await delta in APIClient(apiKey: key).stream(messages: [
            .init(role: "system", content: "Answer accurately and briefly."),
            .init(role: "user", content: "你好"), .init(role: "assistant", content: "你好，有什么可以帮你？"),
            .init(role: "user", content: "请只回答图片中的三位数字。", imageDataURLs: [attachment.dataURL])
        ], model: "deepseek-flash", thinking: true, reasoningEffort: "low") {
            if case .content(let value) = delta { answer += value }
        }
        XCTAssertTrue(answer.contains("742"), "Actual generated camera-style JPEG should be understood")
        XCTAssertFalse(answer.localizedCaseInsensitiveContains("unsupported image"))
        let web = DeepSeekWebService(key: { key })
        let result = try await web.gather(query: "DeepSeek official API search fetch", limit: 1)
        XCTAssertEqual(result.providerUsed, .deepSeek)
        XCTAssertFalse(result.sources.isEmpty)
        XCTAssertTrue(result.sources.contains { !$0.pageText.isEmpty }, "Actual official Fetch must return page content")
        let directory = URL(fileURLWithPath: env["CLIENT_SMOKE_REPORT_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report: [String: Any] = ["imageAnswer": answer, "imageTransport": "Files API file_id; one-hour expiry",
            "provider": result.providerUsed.rawValue, "sourceCount": result.sources.count,
            "successfulFetchCount": result.sources.filter { !$0.pageText.isEmpty }.count,
            "sourceURLs": result.sources.map { $0.url.absoluteString }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("client-media-web-smoke.json"))
    }
}
