import Foundation
import XCTest
@testable import PersonalDeepSeek

private struct CollectionHTTP: ResearchHTTPFetching {
    let action: @Sendable (URLRequest) async throws -> ResearchHTTPResponse
    func data(for request: URLRequest) async throws -> ResearchHTTPResponse { try await action(request) }
}
private struct CollectionDNS: ResearchDNSResolving {
    func addresses(for host: String) async throws -> [String] { ["8.8.8.8"] }
}
private struct CollectionPrivateDNS: ResearchDNSResolving {
    func addresses(for host: String) async throws -> [String] { ["10.0.0.1"] }
}
private actor CollectionCalls {
    var requests: [URLRequest] = []
    var observations: [ResearchPlanningCoordinator.Snapshot] = []
    func record(_ request: URLRequest, _ snapshot: ResearchPlanningCoordinator.Snapshot? = nil) {
        requests.append(request)
        if let snapshot { observations.append(snapshot) }
    }
}
private final class CollectionRedirectProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
            headerFields: ["Location": "https://redirect.example/"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ResearchCollectionTests: XCTestCase {
    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private static func response(_ request: URLRequest, status: Int = 200, text: String,
                                 headers: [String: String] = [:]) -> ResearchHTTPResponse {
        .init(data: Data(text.utf8), url: request.url!, statusCode: status, headers: headers)
    }
    private static func rss(_ urls: [String]) -> String {
        "<rss><channel>" + urls.map { "<item><title>Title</title><link>\($0)</link><description>Snippet</description></item>" }.joined() + "</channel></rss>"
    }
    private func coordinator(queries: [String] = ["one"], searches: Int = 10, fetches: Int = 10,
                             sources: Int = 10, characters: Int = 10_000, clock: PlanningTestClock? = nil) throws -> ResearchPlanningCoordinator {
        let run = try ResearchRun(conversationID: UUID(), query: "question",
            budget: .init(rounds: 2, queries: 10, sources: sources, fetches: fetches,
                          evidenceCharacters: characters, synthesisTokens: 100, wallSeconds: 100,
                          searchRequests: searches), now: Self.start)
        return ResearchPlanningCoordinator(run: run, limits: try .init(),
            planner: FixtureResearchPlanner(fixture: .init(subquestions: [.init(question: "question", queries: queries)])),
            clock: clock?.injected ?? PlanningTestClock(Self.start).injected)
    }
    private func service(search: CollectionHTTP, page: CollectionHTTP? = nil, key: String? = nil,
                         ordinary: CollectionHTTP? = nil) -> LocalResearchService {
        LocalResearchService(resolver: CollectionDNS(), searchFetcher: ordinary ?? search,
            pageFetcher: page ?? CollectionHTTP { Self.response($0, text: "page", headers: ["Content-Type": "text/plain"]) },
            accountedSearchFetcher: search, searchAPIKey: { key })
    }

    func testBraveFallbackChargesTwoSearchRequestsBeforeHTTP() async throws {
        let owner = try coordinator(), calls = CollectionCalls()
        let search = CollectionHTTP { request in
            await calls.record(request, await owner.snapshot())
            if request.url!.host == "api.search.brave.com" { return Self.response(request, status: 503, text: "") }
            return Self.response(request, text: Self.rss(["https://source.example/a"]))
        }
        _ = try await owner.plan()
        let result = try await owner.collect(using: service(search: search, key: "fixture"), limits: .init())
        let observations = await calls.observations
        XCTAssertEqual(observations.map { $0.run.usage[.searchRequests]! }, [1, 2])
        XCTAssertEqual(observations.map { $0.run.usage[.queries]! }, [1, 1])
        XCTAssertEqual(result.sources.first?.provider, .bingRSS)
        let state = await owner.snapshot()
        XCTAssertEqual(result.runID, state.run.id)
        XCTAssertEqual(result.conversationID, state.run.conversationID)
        XCTAssertEqual(state.run.usage[.fetches], 1)
        XCTAssertEqual(state.run.phase, .evaluating)
    }

    func testAdmissionExhaustionCannotBeSwallowedByFallbackOrSnippet() async throws {
        let owner = try coordinator(searches: 1), calls = CollectionCalls()
        let search = CollectionHTTP { request in
            await calls.record(request)
            return Self.response(request, status: 503, text: "")
        }
        _ = try await owner.plan()
        do { _ = try await owner.collect(using: service(search: search, key: "fixture"), limits: .init()); XCTFail("Must reject fallback admission") }
        catch { XCTAssertEqual((error as? ResearchHTTPAdmissionError)?.cause as? ResearchRun.ValidationError, .budgetExceeded(.searchRequests)) }
        let requests = await calls.requests, state = await owner.snapshot()
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(state.run.failure, .budgetExhausted)
        let pageOwner = try coordinator(fetches: 1), pages = CollectionCalls()
        let found = CollectionHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) }
        let page = CollectionHTTP { request in
            await pages.record(request)
            return Self.response(request, status: 302, text: "", headers: ["Location": "/b"])
        }
        _ = try await pageOwner.plan()
        do { _ = try await pageOwner.collect(using: service(search: found, page: page), limits: .init()); XCTFail("Must reject page-hop admission") }
        catch { XCTAssertEqual((error as? ResearchHTTPAdmissionError)?.cause as? ResearchRun.ValidationError, .budgetExceeded(.fetches)) }
        let pageRequests = await pages.requests, collection = await pageOwner.collectionSnapshot()
        XCTAssertEqual(pageRequests.count, 1); XCTAssertTrue(collection.sources.isEmpty)
    }

    func testEveryPageRedirectHopIsReservedBeforeHTTP() async throws {
        let owner = try coordinator(), pages = CollectionCalls()
        let search = CollectionHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) }
        let page = CollectionHTTP { request in
            await pages.record(request, await owner.snapshot())
            return request.url!.path == "/a"
                ? Self.response(request, status: 302, text: "", headers: ["Location": "/b"])
                : Self.response(request, text: "body")
        }
        _ = try await owner.plan()
        let result = try await owner.collect(using: service(search: search, page: page), limits: .init())
        let observations = await pages.observations
        XCTAssertEqual(observations.map { $0.run.usage[.fetches]! }, [1, 2])
        XCTAssertEqual(result.sources.first?.source.url.path, "/b")
        XCTAssertEqual(result.sources.first?.requestedURLKey, "https://source.example/a")
    }

    func testDuplicateRequestedURLsKeepAssociationsWithoutRefetch() async throws {
        let owner = try coordinator(queries: ["one", "two"]), pages = CollectionCalls()
        let search = CollectionHTTP { Self.response($0, text: Self.rss(["https://SOURCE.example:443/a#part", "https://source.example/a"])) }
        let page = CollectionHTTP { request in await pages.record(request); return Self.response(request, text: "body") }
        _ = try await owner.plan()
        let result = try await owner.collect(using: service(search: search, page: page), limits: .init())
        XCTAssertEqual(result.sources.count, 1); XCTAssertEqual(result.sources[0].queryIDs, ["query1", "query2"])
        let count = await pages.requests.count, state = await owner.snapshot()
        XCTAssertEqual(count, 1); XCTAssertEqual(state.run.usage[.sources], 1)
        XCTAssertEqual(state.run.usage[.evidenceCharacters], result.sources[0].characterCost)
        let repeated = try await owner.collect(using: service(search: search, page: page), limits: .init())
        XCTAssertEqual(repeated, result)
        let after = await owner.snapshot(); XCTAssertEqual(after, state)
    }

    func testSourceCeilingPreventsFetchAndDistinctAliasesRemainDistinct() async throws {
        let owner = try coordinator(sources: 1), pages = CollectionCalls()
        let search = CollectionHTTP { Self.response($0, text: Self.rss(["https://source.example/a", "https://source.example/b"])) }
        let page = CollectionHTTP { request in await pages.record(request); return Self.response(request, text: "body") }
        _ = try await owner.plan()
        let result = try await owner.collect(using: service(search: search, page: page), limits: .init())
        let count = await pages.requests.count
        XCTAssertEqual(result.sources.count, 1); XCTAssertEqual(count, 1)
        let limits = try ResearchCollectionLimits()
        XCTAssertNotEqual(try limits.key(for: URL(string: "https://source.example/a?q=%2F")!),
                          try limits.key(for: URL(string: "https://source.example/a?q=/")!))
    }

    func testRetainedSourceAndCharacterReservationIsAtomicAfterHTTP() async throws {
        let owner = try coordinator(characters: 1), pages = CollectionCalls()
        let search = CollectionHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) }
        let page = CollectionHTTP { request in await pages.record(request); return Self.response(request, text: "body") }
        _ = try await owner.plan()
        do { _ = try await owner.collect(using: service(search: search, page: page), limits: .init()); XCTFail("Must reject retained text") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .budgetExceeded(.evidenceCharacters)) }
        let state = await owner.snapshot(), result = await owner.collectionSnapshot()
        XCTAssertEqual(state.run.usage[.sources], 0); XCTAssertEqual(state.run.usage[.evidenceCharacters], 0)
        XCTAssertEqual(state.run.usage[.fetches], 1); XCTAssertTrue(result.sources.isEmpty)
    }

    func testPageFailureKeepsBoundedMarkedSnippetAndUTF8Limit() async throws {
        let owner = try coordinator()
        let search = CollectionHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) }
        let page = CollectionHTTP { _ in throw LocalResearchError.invalidPage }
        _ = try await owner.plan()
        let limits = try ResearchCollectionLimits(textCharacters: 3, textBytes: 4)
        let result = try await owner.collect(using: service(search: search, page: page), limits: limits)
        XCTAssertFalse(result.sources[0].pageFetched); XCTAssertEqual(result.sources[0].source.snippet, "Sni")
        XCTAssertEqual(result.sources[0].source.pageText, "")
        XCTAssertEqual(limits.clipped("😀😀"), "😀")
        XCTAssertEqual(limits.clipped("e\u{301}"), "e\u{301}")
        XCTAssertEqual(limits.clipped("a" + String(repeating: "\u{301}", count: 100)), "")
    }

    func testEmptyResultsEvaluateButHTTPFailureTerminalizes() async throws {
        let owner = try coordinator()
        _ = try await owner.plan()
        let empty = CollectionHTTP { Self.response($0, text: Self.rss([])) }
        let result = try await owner.collect(using: service(search: empty), limits: .init())
        XCTAssertTrue(result.sources.isEmpty)
        let state = await owner.snapshot(); XCTAssertEqual(state.run.phase, .evaluating)
        let failed = try coordinator(); _ = try await failed.plan()
        let bad = CollectionHTTP { Self.response($0, status: 500, text: "") }
        do { _ = try await failed.collect(using: service(search: bad), limits: .init()); XCTFail("Must fail") } catch {}
        let failure = await failed.snapshot(); XCTAssertEqual(failure.run.failure, .providerUnavailable)
    }

    func testLimitsAndURLIdentityRejectOversizeWithoutTruncation() throws {
        XCTAssertThrowsError(try ResearchCollectionLimits(maxSources: 0))
        XCTAssertThrowsError(try ResearchCollectionLimits(resultsPerQuery: 11))
        XCTAssertThrowsError(try ResearchCollectionLimits(textBytes: 96_001))
        let limits = try ResearchCollectionLimits(urlCharacters: 30)
        XCTAssertThrowsError(try limits.key(for: URL(string: "https://source.example/" + String(repeating: "a", count: 30))!))
    }

    func testOrdinarySearchRetainsItsDefaultFetcherWhileAccountedRejectsRedirect() async throws {
        let ordinary = CollectionHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) }
        let accounted = CollectionHTTP { Self.response($0, status: 302, text: "", headers: ["Location": "https://elsewhere.example/"]) }
        let shared = service(search: accounted, ordinary: ordinary)
        let ordinaryRows = try await shared.search(query: "one")
        XCTAssertEqual(ordinaryRows.count, 1)
        do { _ = try await shared.searchWithMetadata(query: "one", admission: { _ in }); XCTFail("Must reject search redirect") }
        catch { guard case LocalResearchError.searchFailed(302) = error else { return XCTFail("Unexpected \(error)") } }
    }

    func testProductionNoRedirectFactoryUsesDelegateAndReturnsOffline302() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CollectionRedirectProtocol.self]
        let fetcher = ResearchHTTPFetcherFactory.noRedirect(configuration: configuration)
        defer { fetcher.session.invalidateAndCancel() }
        let delegate = try XCTUnwrap(fetcher.session.delegate as? ResearchNoRedirectDelegate)
        let request = URLRequest(url: URL(string: "https://source.example/")!)
        let response = try await fetcher.data(for: request)
        XCTAssertEqual(response.statusCode, 302); XCTAssertEqual(response.url, request.url)
        let task = fetcher.session.dataTask(with: request)
        delegate.urlSession(fetcher.session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://redirect.example/")!)) { XCTAssertNil($0) }
    }

    func testCancellationLateResponseCannotRetainOrDebitPageWorkAndOverlapRejects() async throws {
        let owner = try coordinator(), calls = CollectionCalls()
        let search = CollectionHTTP { request in
            await calls.record(request)
            let forbidden = LocalResearchService(resolver: CollectionDNS(), searchAPIKey: { nil })
            do { _ = try await owner.collect(using: forbidden, limits: .init()); XCTFail("Overlap must reject") }
            catch { XCTAssertEqual(error as? ResearchPlanningError, .operationInProgress) }
            try await owner.cancel()
            // An uncooperative response arrives after terminal cancellation.
            return Self.response(request, text: Self.rss(["https://source.example/a"]))
        }
        _ = try await owner.plan()
        do { _ = try await owner.collect(using: service(search: search), limits: .init()); XCTFail("Cancel must win") }
        catch { XCTAssertTrue(error is CancellationError) }
        let state = await owner.snapshot(), result = await owner.collectionSnapshot()
        XCTAssertEqual(state.run.phase, .cancelled); XCTAssertEqual(state.run.usage[.searchRequests], 1)
        XCTAssertEqual(state.run.usage[.fetches], 0); XCTAssertEqual(state.run.usage[.sources], 0)
        XCTAssertTrue(result.sources.isEmpty)
    }

    func testOriginalDeadlineRejectsLateResultAndIdempotentCollection() async throws {
        let clock = PlanningTestClock(Self.start), owner = try coordinator(clock: clock)
        let search = CollectionHTTP { request in
            clock.advance(to: Self.start.addingTimeInterval(100))
            return Self.response(request, text: Self.rss(["https://source.example/a"]))
        }
        _ = try await owner.plan()
        do { _ = try await owner.collect(using: service(search: search), limits: .init()); XCTFail("Deadline must win") } catch {}
        let state = await owner.snapshot(), result = await owner.collectionSnapshot()
        XCTAssertEqual(state.run.failure, .budgetExhausted); XCTAssertEqual(state.run.usage[.searchRequests], 1)
        XCTAssertEqual(state.run.usage[.fetches], 0); XCTAssertTrue(result.sources.isEmpty)
        let finishedClock = PlanningTestClock(Self.start), finished = try coordinator(clock: finishedClock)
        let empty = CollectionHTTP { Self.response($0, text: Self.rss([])) }
        _ = try await finished.plan()
        _ = try await finished.collect(using: service(search: empty), limits: .init())
        finishedClock.advance(to: Self.start.addingTimeInterval(100))
        do { _ = try await finished.collect(using: service(search: empty), limits: .init()); XCTFail("Idempotence cannot reset wall deadline") } catch {}
        let ended = await finished.snapshot(); XCTAssertEqual(ended.run.failure, .budgetExhausted)
    }

    func testAdmissionHookErrorOrCancellationNeverStartsHTTP() async throws {
        let calls = CollectionCalls()
        let fetcher = CollectionHTTP { request in await calls.record(request); return Self.response(request, text: "") }
        let shared = service(search: fetcher, key: "fixture")
        do {
            _ = try await shared.searchWithMetadata(query: "one", admission: { _ in throw ResearchRun.ValidationError.budgetExceeded(.searchRequests) })
            XCTFail("Hook rejection must propagate")
        } catch { XCTAssertEqual((error as? ResearchHTTPAdmissionError)?.cause as? ResearchRun.ValidationError, .budgetExceeded(.searchRequests)) }
        do { _ = try await shared.fetch(.init(title: "t", url: URL(string: "https://source.example/")!, snippet: "s"), admission: { _ in throw CancellationError() }); XCTFail("Cancel hook must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await calls.requests.count; XCTAssertEqual(count, 0)
    }

    func testLatePageOutputAfterCancellationOrDeadlineNeverRetainsButKeepsHTTPCharge() async throws {
        for cancellation in [true, false] {
            let clock = PlanningTestClock(Self.start), owner = try coordinator(clock: clock)
            let search = CollectionHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) }
            let page = CollectionHTTP { request in
                if cancellation { try await owner.cancel() }
                else { clock.advance(to: Self.start.addingTimeInterval(100)) }
                return Self.response(request, text: "late body")
            }
            _ = try await owner.plan()
            do { _ = try await owner.collect(using: service(search: search, page: page), limits: .init()); XCTFail("Late output must reject") } catch {}
            let state = await owner.snapshot(), result = await owner.collectionSnapshot()
            XCTAssertEqual(state.run.usage[.searchRequests], 1); XCTAssertEqual(state.run.usage[.fetches], 1)
            XCTAssertEqual(state.run.usage[.sources], 0); XCTAssertEqual(state.run.usage[.evidenceCharacters], 0)
            XCTAssertEqual(state.run.phase, cancellation ? .cancelled : .failed)
            if !cancellation { XCTAssertEqual(state.run.failure, .budgetExhausted) }
            XCTAssertTrue(result.sources.isEmpty)
        }
    }

    func testPageClockValidationErrorCannotBecomeSnippetSuccess() async throws {
        let clock = PlanningTestClock(Self.start), owner = try coordinator(clock: clock)
        let search = CollectionHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) }
        let page = CollectionHTTP { request in
            clock.advance(to: Self.start.addingTimeInterval(-1))
            return Self.response(request, text: "body")
        }
        _ = try await owner.plan()
        do { _ = try await owner.collect(using: service(search: search, page: page), limits: .init()); XCTFail("Clock must reject") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .invalidClock) }
        let state = await owner.snapshot(), collection = await owner.collectionSnapshot()
        XCTAssertEqual(state.run.failure, .internalError); XCTAssertTrue(collection.sources.isEmpty)
        XCTAssertEqual(state.run.usage[.fetches], 1)
        let controlOwner = try coordinator(); _ = try await controlOwner.plan()
        let control = CollectionHTTP { _ in throw ResearchRun.ValidationError.invalidClock }
        do { _ = try await controlOwner.collect(using: service(search: search, page: control), limits: .init()); XCTFail("Control error cannot fallback") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .invalidClock) }
        let controlResult = await controlOwner.collectionSnapshot(); XCTAssertTrue(controlResult.sources.isEmpty)
    }

    func testDNSRejectionAndOversizedCandidatePreventPageAdmission() async throws {
        let owner = try coordinator(), pages = CollectionCalls()
        let search = CollectionHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) }
        let page = CollectionHTTP { request in await pages.record(request); return Self.response(request, text: "body") }
        let privateService = LocalResearchService(resolver: CollectionPrivateDNS(), pageFetcher: page,
                                                 accountedSearchFetcher: search, searchAPIKey: { nil })
        _ = try await owner.plan()
        let result = try await owner.collect(using: privateService, limits: .init())
        XCTAssertFalse(result.sources[0].pageFetched)
        let state = await owner.snapshot(); XCTAssertEqual(state.run.usage[.fetches], 0)
        let oversized = try coordinator(); _ = try await oversized.plan()
        let dropped = try await oversized.collect(using: service(search: search, page: page), limits: .init(urlCharacters: 5))
        XCTAssertTrue(dropped.sources.isEmpty)
        let oversizedState = await oversized.snapshot(), requests = await pages.requests
        XCTAssertEqual(oversizedState.run.usage[.fetches], 0); XCTAssertTrue(requests.isEmpty)
        let byteLimits = try ResearchCollectionLimits(urlCharacters: 8_192, urlBytes: 5)
        XCTAssertThrowsError(try byteLimits.key(for: URL(string: "https://source.example/a")!))
    }

    func testRetainedMultibyteFieldsAreClippedAndHostSourceCeilingKeepsDuplicateLinks() async throws {
        let owner = try coordinator(queries: ["one", "two"]), pages = CollectionCalls()
        let search = CollectionHTTP { request in
            let rss = Self.rss(["https://source.example/a", "https://source.example/b"])
                .replacingOccurrences(of: "Title", with: "😀😀").replacingOccurrences(of: "Snippet", with: "😀😀")
            return Self.response(request, text: rss)
        }
        let page = CollectionHTTP { request in await pages.record(request); return Self.response(request, text: "😀😀") }
        _ = try await owner.plan()
        let result = try await owner.collect(using: service(search: search, page: page), limits: .init(maxSources: 1, textCharacters: 3, textBytes: 4))
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources[0].queryIDs, ["query1", "query2"])
        XCTAssertEqual(result.sources[0].source.title, "😀"); XCTAssertEqual(result.sources[0].source.snippet, "😀")
        XCTAssertEqual(result.sources[0].source.pageText, "😀")
        let state = await owner.snapshot(), requests = await pages.requests
        XCTAssertEqual(state.run.usage[.evidenceCharacters], result.sources[0].characterCost)
        XCTAssertEqual(requests.count, 1)
    }

    func testCancellationReturningFromAdmissionHookCannotStartHTTP() async throws {
        let calls = CollectionCalls()
        let fetcher = CollectionHTTP { request in await calls.record(request); return Self.response(request, text: "") }
        let shared = service(search: fetcher)
        let task = Task {
            try await shared.searchWithMetadata(query: "one", admission: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                // A hook can ignore cancellation; the shared HTTP boundary still checks it.
            })
        }
        do { _ = try await task.value; XCTFail("Cancelled hook cannot start HTTP") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await calls.requests; XCTAssertTrue(requests.isEmpty)
    }
}
