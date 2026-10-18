import Foundation
import XCTest
@testable import PersonalDeepSeek

private final class ImageHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var uploadStatus = 200
    private var fileID = "file-api-test-image"
    func configure(status: Int = 200, fileID: String = "file-api-test-image") {
        lock.lock(); defer { lock.unlock() }
        requests = []; uploadStatus = status; self.fileID = fileID
    }
    func response(_ request: URLRequest) -> (Int, Data, String) {
        lock.lock(); defer { lock.unlock() }; requests.append(request)
        if request.url?.path == "/files" {
            let data = try! JSONSerialization.data(withJSONObject: ["id": fileID])
            return (uploadStatus, data, "application/json")
        }
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"742\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        return (200, Data(sse.utf8), "text/event-stream")
    }
    func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

private final class ImageHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = ImageHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data, type) = Self.state.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor final class ClientImageTransportTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageHTTPProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func run(_ client: APIClient, url: String, model: String = "deepseek-flash") async throws -> String {
        var answer = ""
        for try await delta in client.stream(messages: [.init(role: "user", content: "Read the image", imageDataURLs: [url])],
            model: model, thinking: false, reasoningEffort: "low") {
            if case .content(let value) = delta { answer += value }
        }
        return answer
    }

    func testUploadBeforeCompletionAndReuseWithinClient() async throws {
        ImageHTTPProtocol.state.configure()
        let session = session(); defer { session.invalidateAndCancel() }
        let client = APIClient(apiKey: "image-fixture-key", session: session)
        let image = try ClientImageTests.testImage()
        let first = try await run(client, url: image.dataURL)
        let second = try await run(client, url: image.dataURL)
        XCTAssertEqual(first, "742"); XCTAssertEqual(second, "742")
        let requests = ImageHTTPProtocol.state.captured()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/files", "/chat/completions", "/chat/completions"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer image-fixture-key" })
    }

    func testUploadFailureNeverStartsTextOnlyCompletion() async throws {
        ImageHTTPProtocol.state.configure(status: 401)
        let session = session(); defer { session.invalidateAndCancel() }
        do {
            _ = try await run(APIClient(apiKey: "image-fixture-key", session: session), url: ClientImageTests.testImage().dataURL)
            XCTFail("Upload failure must stop generation")
        } catch { XCTAssertEqual(error as? ChatImageError, .uploadFailed(401)) }
        XCTAssertEqual(ImageHTTPProtocol.state.captured().map { $0.url?.path }, ["/files"])
    }

    func testInvalidImageAndUnsupportedModelStopBeforeAnyUpload() async throws {
        ImageHTTPProtocol.state.configure()
        let session = session(); defer { session.invalidateAndCancel() }
        let client = APIClient(apiKey: "image-fixture-key", session: session)
        do { _ = try await run(client, url: "data:image/jpeg;base64,YQ=="); XCTFail() }
        catch { XCTAssertEqual(error as? ChatImageError, .invalidImage) }
        do { _ = try await run(client, url: ClientImageTests.testImage().dataURL, model: "deepseek-v4-pro"); XCTFail() }
        catch {
            guard case .modelDoesNotSupportImages(let name) = error as? ClientError else { return XCTFail("Expected model image guard") }
            XCTAssertEqual(name, "deepseek-v4-pro")
        }
        XCTAssertTrue(ImageHTTPProtocol.state.captured().isEmpty)
    }

    func testInvalidFileIDStopsBeforeCompletion() async throws {
        ImageHTTPProtocol.state.configure(fileID: "invalid-id")
        let session = session(); defer { session.invalidateAndCancel() }
        do {
            _ = try await run(APIClient(apiKey: "image-fixture-key", session: session), url: ClientImageTests.testImage().dataURL)
            XCTFail()
        } catch { XCTAssertEqual(error as? ChatImageError, .invalidUploadResponse) }
        XCTAssertEqual(ImageHTTPProtocol.state.captured().count, 1)
    }
}
