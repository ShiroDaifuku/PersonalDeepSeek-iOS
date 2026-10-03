import Foundation
import XCTest
@testable import PersonalDeepSeek

private final class PlannerStreamFixture: AgentModelStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AgentModelRequest] = []
    let deltas: [StreamDelta]
    let error: Error?
    init(_ deltas: [StreamDelta], error: Error? = nil) { self.deltas = deltas; self.error = error }
    var requests: [AgentModelRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func streamRound(_ request: AgentModelRequest) -> AsyncThrowingStream<StreamDelta, Error> {
        lock.lock(); recorded.append(request); lock.unlock()
        return AsyncThrowingStream { continuation in
            deltas.forEach { continuation.yield($0) }
            continuation.finish(throwing: error)
        }
    }
}

private final class PlannerHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var payload = Data()
    private var hold = false
    private var calls = 0
    private var stopped = 0
    private var started: (@Sendable () -> Void)?
    private var ended: (@Sendable () -> Void)?
    private var release: (@Sendable () -> Void)?
    func configure(status: Int = 200, body: String, hold: Bool = false,
                   started: (@Sendable () -> Void)? = nil, ended: (@Sendable () -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; payload = Data(body.utf8); self.hold = hold; calls = 0; stopped = 0
        self.started = started; self.ended = ended
        release = nil
    }
    func response() -> (Int, Data, Bool) {
        lock.lock(); calls += 1; let value = (status, payload, hold); let callback = started; lock.unlock()
        callback?(); return value
    }
    func stop() { lock.lock(); stopped += 1; let callback = ended; release = nil; lock.unlock(); callback?() }
    func registerRelease(_ callback: @escaping @Sendable () -> Void) { lock.lock(); release = callback; lock.unlock() }
    func releaseHeldRequest() { lock.lock(); let callback = release; release = nil; lock.unlock(); callback?() }
    func replacePayload(_ data: Data) { lock.lock(); payload = data; lock.unlock() }
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (calls, stopped) }
}

private final class PlannerURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = PlannerHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.registerRelease { [weak self] in
            guard let self else { return }; self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
        let (code, data, hold) = Self.state.response()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        // Single-byte chunks include splits within multi-byte UTF-8 scalars.
        for byte in data { client?.urlProtocol(self, didLoad: Data([byte])) }
        if !hold { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.state.stop() }
}

final class APIClientResearchPlannerTests: XCTestCase {
    private let json = #"{"subquestions":[{"question":"Question A","queries":[" Shared query ","Second"]},{"question":"Question B","queries":["shared QUERY"]}]}"#
    private func input(draftBytes: Int = 32_768, question: String = "Original question") throws -> ResearchPlanningInput {
        .init(runID: UUID(), question: question, limits: try .init(draftBytes: draftBytes))
    }
    private func success(_ text: String) -> [StreamDelta] {
        [.content(text), .finishReason("stop"), .usage(15),
         .detailedUsage(.init(promptTokens: 10, completionTokens: 5)), .done]
    }
    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerURLProtocol.self]
        return APIClient(apiKey: "fixture-key", session: URLSession(configuration: configuration))
    }
    private func sse(_ text: String, usage: String = #"{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}"#) throws -> String {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": text]]]]), as: UTF8.self)
        return "data: \(content)\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: {\"usage\":\(usage)}\n\ndata: [DONE]\n\n"
    }

    func testExactRequestControlsAndDeduplicatedPlan() async throws {
        let fixture = PlannerStreamFixture(success(json))
        let planner = try APIClientResearchPlanner(client: fixture, maxOutputTokens: 128)
        let context = try input(question: "  user-only question  ")
        let draft = try await planner.draft(for: context)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.messages, [.init(role: "system", content: APIClientResearchPlanner.systemPrompt),
                                         .init(role: "user", content: context.question)])
        XCTAssertFalse(request.thinking); XCTAssertEqual(request.reasoningEffort, "none")
        XCTAssertEqual(request.maxOutputTokens, 128); XCTAssertEqual(request.maximumAttempts, 1)
        XCTAssertEqual(request.responseByteLimit, 131_072); XCTAssertTrue(request.toolNames.isEmpty)
        XCTAssertEqual(request.toolChoice, .none); XCTAssertFalse(request.strict)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.requestBody(request)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 128); XCTAssertNil(body["tools"])
        let run = try ResearchRun(conversationID: UUID(), query: context.question,
            budget: .init(rounds: 3, queries: 3, sources: 3, fetches: 3, evidenceCharacters: 3,
                          synthesisTokens: 3, wallSeconds: 100), now: Date())
        let plan = try ResearchPlan(draft: draft, run: run, limits: context.limits)
        XCTAssertEqual(plan.queries.count, 2)
        XCTAssertEqual(plan.subquestions[0].queryIDs.first, plan.subquestions[1].queryIDs.first)
    }

    func testLegacyRequestDefaultsAndInvalidOptions() throws {
        var request = AgentModelRequest(messages: [.init(role: "user", content: "hello")], model: "deepseek-chat",
            thinking: true, reasoningEffort: "high", toolNames: [], toolChoice: .auto)
        XCTAssertEqual(request.maximumAttempts, 3); XCTAssertNil(request.responseByteLimit)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.requestBody(request)) as? [String: Any])
        XCTAssertNil(body["max_tokens"]); XCTAssertEqual(body["model"] as? String, DeepSeekModelCompatibility.flash)
        for maximum in [0, -1, 393_217] { request.maxOutputTokens = maximum; XCTAssertThrowsError(try APIClient.requestBody(request)) }
        request.maxOutputTokens = nil
        for attempts in [0, 4] { request.maximumAttempts = attempts; XCTAssertThrowsError(try APIClient.requestBody(request)) }
        request.maximumAttempts = 3
        for bytes in [0, 1_048_577] { request.responseByteLimit = bytes; XCTAssertThrowsError(try APIClient.requestBody(request)) }
    }

    func testStrictCompletionUsageAndInvalidOutput() async throws {
        let variants: [[StreamDelta]] = [
            [.content(json), .finishReason("length"), .done], [.content(json), .done],
            [.content(json), .finishReason("stop"), .done], [.reasoning("hidden")],
            [.content("```json\n\(json)\n```"), .finishReason("stop"), .detailedUsage(.init(completionTokens: 5)), .done],
            [.content(json), .finishReason("stop"), .detailedUsage(.init(completionTokens: -1)), .done],
            [.content(json), .finishReason("stop"), .detailedUsage(.init(completionTokens: 9_999)), .done],
            [.content(json), .finishReason("stop"), .detailedUsage(.init(completionTokens: 5, reasoningTokens: 1)), .done],
            [.content(json), .finishReason("stop"), .detailedUsage(.init(completionTokens: 5)), .usage(4), .done],
            [.content(json), .finishReason("stop"), .detailedUsage(.init(completionTokens: 5)), .detailedUsage(.init(completionTokens: 5)), .done],
            [.content(json), .finishReason("stop"), .detailedUsage(.init(promptTokens: Int.max, completionTokens: 5)), .done],
            [.toolCall(.init(index: 0, id: "call", type: "function", name: "web_search", arguments: "{}"))],
            [.content(json), .finishReason("stop"), .detailedUsage(.init(completionTokens: 5))]
        ]
        for (index, events) in variants.enumerated() {
            do { _ = try await APIClientResearchPlanner(client: PlannerStreamFixture(events)).draft(for: input()); XCTFail("Accepted invalid output") }
            catch {
                if index == 4 { XCTAssertTrue(error is DecodingError) }
                else { XCTAssertEqual(error as? ResearchPlannerError, .invalidResponse) }
            }
        }
    }

    func testContentByteCapAndInputCapBeforeProvider() async throws {
        let fixture = PlannerStreamFixture([.content(String(repeating: "界", count: 4))])
        do { _ = try await APIClientResearchPlanner(client: fixture).draft(for: input(draftBytes: 10)); XCTFail("Accepted overflow") }
        catch { XCTAssertEqual(error as? ResearchPlannerError, .invalidResponse) }
        let untouched = PlannerStreamFixture(success(json))
        do { _ = try await APIClientResearchPlanner(client: untouched, questionByteLimit: 3).draft(for: input(question: "界界")); XCTFail("Accepted input") }
        catch { XCTAssertEqual(error as? ResearchPlannerError, .invalidInput) }
        XCTAssertTrue(untouched.requests.isEmpty)
    }

    func testRealTransportSuccessAndStrictRawUsage() async throws {
        let unicodeJSON = json.replacingOccurrences(of: "Question A", with: "研究问题 🧪")
        PlannerURLProtocol.state.configure(body: try sse(unicodeJSON))
        let draft = try await APIClientResearchPlanner(client: client()).draft(for: input())
        XCTAssertEqual(draft.subquestions.count, 2)
        XCTAssertEqual(draft.subquestions[0].question, "研究问题 🧪")
        for usage in [#"{"prompt_tokens":true,"completion_tokens":5,"total_tokens":6}"#,
                      #"{"prompt_tokens":1.5,"completion_tokens":5,"total_tokens":6}"#,
                      #"{"completion_tokens":5,"total_tokens":5}"#,
                      #"{"prompt_tokens":0,"completion_tokens":-1,"total_tokens":0}"#,
                      #"{"prompt_tokens":"10","completion_tokens":5,"total_tokens":15}"#,
                      #"{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"completion_tokens_details":{"reasoning_tokens":"x"}}"#,
                      #"{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_cache_hit_tokens":false}"#,
                      #"{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"completion_tokens_details":[]}"#] {
            PlannerURLProtocol.state.configure(body: try sse(json, usage: usage))
            do { _ = try await APIClientResearchPlanner(client: client()).draft(for: input()); XCTFail("Accepted malformed raw usage") }
            catch { XCTAssertEqual(error as? ResearchPlannerError, .invalidResponse) }
        }
    }

    func testRawByteLimitCountsCommentsMalformedAndUnterminatedLines() async throws {
        for payload in [":" + String(repeating: "x", count: 200), "data: " + String(repeating: "x", count: 200),
                        String(repeating: ": comment\n", count: 30)] {
            PlannerURLProtocol.state.configure(body: payload)
            do { _ = try await APIClientResearchPlanner(client: client(), responseByteLimit: 64).draft(for: input()); XCTFail("Accepted raw overflow") }
            catch { XCTAssertEqual(error as? ResearchPlannerError, .invalidResponse) }
        }
        PlannerURLProtocol.state.configure(body: "data: not-json\n")
        do { _ = try await APIClientResearchPlanner(client: client()).draft(for: input()); XCTFail("Accepted malformed event") }
        catch { XCTAssertEqual(error as? ResearchPlannerError, .invalidResponse) }
        PlannerURLProtocol.state.configure(body: "")
        PlannerURLProtocol.state.replacePayload(Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0xFF, 0x0A]))
        do { _ = try await APIClientResearchPlanner(client: client()).draft(for: input()); XCTFail("Accepted invalid UTF-8") }
        catch { XCTAssertEqual(error as? ResearchPlannerError, .invalidResponse) }
    }

    func testPlannerHTTPFailuresHaveOneAttemptAndLegacyHasThree() async throws {
        for code in [429, 500] {
            PlannerURLProtocol.state.configure(status: code, body: "")
            do { _ = try await APIClientResearchPlanner(client: client()).draft(for: input()); XCTFail("Accepted HTTP error") }
            catch { XCTAssertEqual(error as? ResearchPlanningError, .providerUnavailable) }
            XCTAssertEqual(PlannerURLProtocol.state.counts.0, 1)
            PlannerURLProtocol.state.configure(status: code, body: "")
            do { for try await _ in client().stream(messages: [.init(role: "user", content: "hello")], model: "deepseek-chat", thinking: false, reasoningEffort: "none") {} }
            catch {
                guard case ClientError.badResponse(let received) = error else { XCTFail("Wrong transport error: \(error)"); continue }
                XCTAssertEqual(received, code)
            }
            XCTAssertEqual(PlannerURLProtocol.state.counts.0, 3)
        }
    }

    func testAtomicPlanningReservationsAndFailureCheckpointRemainCharged() async throws {
        let now = Date()
        for ceiling in [64, 128] {
            let fixture = PlannerStreamFixture([], error: URLError(.notConnectedToInternet))
            let run = try ResearchRun(conversationID: UUID(), query: "question", budget: .init(rounds: 3, queries: 3,
                sources: 3, fetches: 3, evidenceCharacters: 3, synthesisTokens: 3, wallSeconds: 100,
                planningAttempts: 1, planningTokens: ceiling), now: now)
            let coordinator = ResearchPlanningCoordinator(run: run, limits: try .init(),
                planner: try APIClientResearchPlanner(client: fixture, maxOutputTokens: 128))
            do { _ = try await coordinator.plan(); XCTFail("Expected failure") } catch {}
            let snapshot = await coordinator.snapshot()
            XCTAssertEqual(snapshot.run.failure, ceiling == 64 ? .budgetExhausted : .providerUnavailable)
            XCTAssertEqual(snapshot.run.usage[.rounds], ceiling == 64 ? 0 : 1)
            XCTAssertEqual(snapshot.run.usage[.planningAttempts], ceiling == 64 ? 0 : 1)
            XCTAssertEqual(snapshot.run.usage[.planningTokens], ceiling == 64 ? 0 : 128)
            XCTAssertEqual(fixture.requests.count, ceiling == 64 ? 0 : 1)
            XCTAssertEqual(try JSONDecoder().decode(ResearchRun.self, from: JSONEncoder().encode(snapshot.run)), snapshot.run)
        }
    }

    func testActualTransportCancellationAndOriginalDeadlineRetainReservation() async throws {
        for deadline in [false, true] {
            let started = expectation(description: "HTTP started")
            let stopped = expectation(description: "HTTP cancelled")
            let completed = expectation(description: "Planning exited")
            PlannerURLProtocol.state.configure(body: ": waiting\n", hold: true,
                started: { started.fulfill() }, ended: { stopped.fulfill() })
            let original = Date(timeIntervalSinceReferenceDate: 1_000)
            let clock = PlanningTestClock(original.addingTimeInterval(9))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PlannerURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let run = try ResearchRun(conversationID: UUID(), query: "question", budget: .init(rounds: 3, queries: 3,
                sources: 3, fetches: 3, evidenceCharacters: 3, synthesisTokens: 3, wallSeconds: 10,
                planningAttempts: 1, planningTokens: 128), now: original)
            let coordinator = ResearchPlanningCoordinator(run: run, limits: try .init(),
                planner: try APIClientResearchPlanner(client: APIClient(apiKey: "fixture-key", session: session),
                    maxOutputTokens: 128), clock: clock.injected)
            let task = Task { () -> Result<ResearchPlan, Error> in
                defer { completed.fulfill() }
                do { return .success(try await coordinator.plan()) } catch { return .failure(error) }
            }
            await fulfillment(of: [started], timeout: 30)
            let during = await coordinator.snapshot()
            XCTAssertEqual(during.run.usage[.planningTokens], 128)
            XCTAssertEqual(during.run.usage[.planningAttempts], 1)
            XCTAssertEqual(during.run.usage[.rounds], 1)
            if deadline { clock.advance(to: original.addingTimeInterval(10)) } else { task.cancel() }
            await fulfillment(of: [completed, stopped], timeout: 30)
            // Ensure a failing cancellation regression produces a test failure, not a hung suite.
            PlannerURLProtocol.state.releaseHeldRequest()
            session.invalidateAndCancel()
            task.cancel(); clock.advance(to: original.addingTimeInterval(20))
            switch await task.value {
            case .success: XCTFail("Stalled request succeeded")
            case .failure(let error):
                if deadline { XCTAssertEqual(error as? ResearchPlanningError, .deadlineExceeded) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            let after = await coordinator.snapshot()
            XCTAssertEqual(after.run.phase, deadline ? .failed : .cancelled)
            XCTAssertEqual(after.run.failure, deadline ? .budgetExhausted : nil)
            XCTAssertEqual(after.run.usage, during.run.usage)
        }
    }

    func testRestoredQueuedCheckpointCannotResetPlanningBudget() async throws {
        let now = Date()
        var run = try ResearchRun(conversationID: UUID(), query: "question", budget: .init(rounds: 3, queries: 3,
            sources: 3, fetches: 3, evidenceCharacters: 3, synthesisTokens: 3, wallSeconds: 100,
            planningAttempts: 1, planningTokens: 128), now: now)
        try run.reserve([.planningAttempts: 1, .planningTokens: 128], at: now)
        let restored = try JSONDecoder().decode(ResearchRun.self, from: JSONEncoder().encode(run))
        let fixture = PlannerStreamFixture(success(json))
        let coordinator = ResearchPlanningCoordinator(run: restored, limits: try .init(),
            planner: try APIClientResearchPlanner(client: fixture, maxOutputTokens: 128))
        do { _ = try await coordinator.plan(); XCTFail("Reset budget") } catch {}
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.run.usage, restored.usage)
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertEqual(snapshot.run.failure, .budgetExhausted)
    }
}
