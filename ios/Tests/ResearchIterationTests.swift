import Foundation
import XCTest
@testable import PersonalDeepSeek

private struct IterationHTTP: ResearchHTTPFetching {
    let action: @Sendable (URLRequest) async throws -> ResearchHTTPResponse
    func data(for request: URLRequest) async throws -> ResearchHTTPResponse { try await action(request) }
}
private struct IterationDNS: ResearchDNSResolving {
    func addresses(for host: String) async throws -> [String] { ["8.8.8.8"] }
}
private actor IterationCalls {
    var requests: [URLRequest] = []
    var observations: [ResearchPlanningCoordinator.Snapshot] = []
    func record(_ request: URLRequest, _ observation: ResearchPlanningCoordinator.Snapshot? = nil) {
        requests.append(request); if let observation { observations.append(observation) }
    }
}
/// Deliberately holds a late fixture response until explicitly released by the test.
private actor IterationGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var responseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { responseWaiter = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { responseWaiter?.resume(); responseWaiter = nil }
}

private final class IterationExpiryClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base: PlanningTestClock
    private let start: Date
    private var remaining: Int?
    init(_ start: Date) { self.start = start; base = PlanningTestClock(start) }
    func expireAfter(reads: Int) { lock.withLock { remaining = reads } }
    private func now() -> Date {
        lock.withLock {
            guard let reads = remaining else { return start }
            if reads == 0 { return start.addingTimeInterval(100) }
            remaining = reads - 1; return start
        }
    }
    var injected: ResearchPlanningClock { .init(now: { self.now() }, sleepUntil: base.injected.sleepUntil) }
}

final class ResearchIterationTests: XCTestCase {
    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private static func response(_ request: URLRequest, status: Int = 200, text: String,
                                 headers: [String: String] = [:]) -> ResearchHTTPResponse {
        .init(data: Data(text.utf8), url: request.url!, statusCode: status, headers: headers)
    }
    private static func rss(_ urls: [String]) -> String {
        "<rss><channel>" + urls.map { "<item><title>Title</title><link>\($0)</link><description>Snippet</description></item>" }.joined() + "</channel></rss>"
    }
    private func service(search: IterationHTTP? = nil, page: IterationHTTP? = nil, key: String? = nil) -> LocalResearchService {
        LocalResearchService(resolver: IterationDNS(),
            pageFetcher: page ?? IterationHTTP { Self.response($0, text: "Page", headers: ["Content-Type": "text/plain"]) },
            accountedSearchFetcher: search ?? IterationHTTP { Self.response($0, text: Self.rss([])) }, searchAPIKey: { key })
    }
    private func makeOwner(rounds: Int = 3, queries: Int = 10, searches: Int = 20, fetches: Int = 10,
                           sources: Int = 10, characters: Int = 100_000, clock: PlanningTestClock? = nil,
                           initial: LocalResearchService? = nil, questions: [String] = ["one"],
                           planningLimits: ResearchPlanningLimits = try! .init(),
                           collectionLimits: ResearchCollectionLimits = try! .init(),
                           evidenceLimits: ResearchEvidenceLimits = try! .init(),
                           coverageLimits: ResearchCoverageLimits = try! .init(), projections: Bool = true,
                           injectedClock: ResearchPlanningClock? = nil) async throws -> ResearchPlanningCoordinator {
        let run = try ResearchRun(conversationID: UUID(), query: "Original question",
            budget: .init(rounds: rounds, queries: queries, sources: sources, fetches: fetches,
                evidenceCharacters: characters, synthesisTokens: 100, wallSeconds: 100, searchRequests: searches), now: Self.start)
        let draft = ResearchPlannerDraft(subquestions: questions.map { .init(question: $0, queries: [$0]) })
        let owner = ResearchPlanningCoordinator(run: run, limits: planningLimits, planner: FixtureResearchPlanner(fixture: draft),
            clock: injectedClock ?? clock?.injected ?? PlanningTestClock(Self.start).injected)
        _ = try await owner.plan(); _ = try await owner.collect(using: initial ?? service(), limits: collectionLimits)
        if projections {
            _ = try await owner.buildEvidenceLedger(limits: evidenceLimits)
            _ = try await owner.buildCoverage(limits: coverageLimits)
        }
        return owner
    }
    private func draft(_ query: String = "new", question: String = "question1",
                       gap: ResearchCoverageReport.Gap = .noAssociatedSources) -> ResearchRefinementDraft {
        .init(targets: [.init(questionID: question, gaps: [gap], queries: [query])])
    }
    private func proposal(_ owner: ResearchPlanningCoordinator, _ draft: ResearchRefinementDraft? = nil) async throws -> ResearchRefinementProposal {
        try await owner.buildRefinement(draft: draft ?? self.draft(), limits: .init())
    }
    private func iterate(_ owner: ResearchPlanningCoordinator, _ proposal: ResearchRefinementProposal,
                         service: LocalResearchService? = nil, limits: ResearchCollectionLimits = try! .init()) async throws -> ResearchCoverageReport {
        try await owner.iterate(expectedProposalContextDigest: proposal.contextDigest, using: service ?? self.service(), collectionLimits: limits)
    }

    private func pureProposal(_ owner: ResearchPlanningCoordinator, _ draft: ResearchRefinementDraft) async throws -> ResearchRefinementProposal {
        let state = await owner.snapshot(), plan = try XCTUnwrap(state.plan), collection = await owner.collectionSnapshot()
        let ledger = try await owner.buildEvidenceLedger(limits: .init()), coverage = try await owner.buildCoverage(limits: .init())
        return try .build(draft: draft, run: state.run, plan: plan, planningLimits: plan.limits,
            collection: collection, ledger: ledger, evidenceLimits: ledger.limits, coverage: coverage,
            coverageLimits: coverage.limits, attemptedQueryIDs: state.attemptedQueryIDs, limits: .init())
    }

    func testThreeRoundsAppendOnlyQueriesAndKeepOriginalPlanIdentity() async throws {
        let owner = try await makeOwner(), original = await owner.snapshot()
        let first = try await proposal(owner, draft("second")); _ = try await iterate(owner, first)
        let second = try await proposal(owner, draft("third")); let report = try await iterate(owner, second)
        let final = await owner.snapshot(), plan = try XCTUnwrap(final.plan)
        XCTAssertEqual(plan.queries.map(\.id), ["query1", "query2", "query3"])
        XCTAssertEqual(plan.queries.map(\.text), ["one", "second", "third"])
        XCTAssertEqual(plan.subquestions[0].queryIDs, ["query1", "query2", "query3"])
        XCTAssertEqual(plan.originalQuestion, original.plan?.originalQuestion)
        XCTAssertEqual(plan.runID, original.run.id); XCTAssertEqual(plan.conversationID, original.run.conversationID)
        XCTAssertEqual(final.attemptedQueryIDs, ["query1", "query2", "query3"])
        XCTAssertEqual(final.run.usage[.rounds], 3); XCTAssertEqual(final.run.usage[.queries], 3)
        XCTAssertEqual(final.run.usage[.searchRequests], 3); XCTAssertEqual(final.run.phase, .evaluating)
        XCTAssertEqual(report.questions[0].gaps, [.noAssociatedSources, .noRetainedEntries])
        XCTAssertEqual(ResearchRun.checkpointVersion, 3)
    }

    func testReorderedTargetsDoNotRenumberOrReorderProposalQueries() async throws {
        let owner = try await makeOwner(questions: ["one", "two"])
        let input = ResearchRefinementDraft(targets: [draft("for second", question: "question2").targets[0], draft("for first").targets[0]])
        let next = try await proposal(owner, input)
        XCTAssertEqual(next.targets.map(\.questionID), ["question1", "question2"])
        XCTAssertEqual(next.queries.map(\.text), ["for second", "for first"])
        _ = try await iterate(owner, next)
        let state = await owner.snapshot(), plan = try XCTUnwrap(state.plan)
        XCTAssertEqual(plan.queries.map(\.text), ["one", "two", "for second", "for first"])
        XCTAssertEqual(plan.subquestions[0].queryIDs, ["query1", "query4"])
        XCTAssertEqual(plan.subquestions[1].queryIDs, ["query2", "query3"])
    }

    func testDuplicateRequestedURLKeepsFirstObservationAndNeverRefetches() async throws {
        let pages = IterationCalls()
        let initial = service(search: IterationHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) },
            page: IterationHTTP { await pages.record($0); return Self.response($0, status: 500, text: "") })
        let owner = try await makeOwner(initial: initial), old = await owner.collectionSnapshot()
        let oldLedger = try await owner.buildEvidenceLedger(limits: .init())
        let next = try await proposal(owner, draft("another", gap: .snippetOnly)), before = await owner.snapshot()
        let calls = IterationCalls()
        let newService = service(search: IterationHTTP {
            await calls.record($0)
            return Self.response($0, text: "{\"web\":{\"results\":[{\"title\":\"Different\",\"url\":\"https://source.example/a#fragment\",\"description\":\"Different snippet\"}]}}")
        }, page: IterationHTTP { await pages.record($0); return Self.response($0, text: "Upgraded", headers: ["Content-Type": "text/plain"]) }, key: "fixture")
        let report = try await iterate(owner, next, service: newService), collection = await owner.collectionSnapshot()
        let ledger = try await owner.buildEvidenceLedger(limits: .init()), after = await owner.snapshot()
        XCTAssertEqual(collection.sources.count, 1); XCTAssertEqual(collection.sources[0].id, "source1")
        XCTAssertEqual(collection.sources[0].provider, .bingRSS); XCTAssertFalse(collection.sources[0].pageFetched)
        XCTAssertEqual(collection.sources[0].source, old.sources[0].source)
        XCTAssertEqual(collection.sources[0].queryIDs, ["query1", "query2"])
        XCTAssertEqual(ledger.entries, oldLedger.entries)
        XCTAssertEqual(report.questions[0].gaps, [.snippetOnly])
        let pageRequests = await pages.requests; XCTAssertEqual(pageRequests.count, 1)
        XCTAssertEqual(after.run.usage[.fetches], before.run.usage[.fetches])
        XCTAssertEqual(after.run.usage[.sources], before.run.usage[.sources])
        XCTAssertEqual(after.run.usage[.evidenceCharacters]! - before.run.usage[.evidenceCharacters]!,
            "query2".count + ledger.metadataCharacterCost + report.metadataCharacterCost)
    }

    func testNewSourcesAndProjectionMetadataHaveExactNineDimensionChargesAndCachedGetters() async throws {
        let owner = try await makeOwner(), next = try await proposal(owner), before = await owner.snapshot(), calls = IterationCalls()
        let found = service(search: IterationHTTP { request in
            await calls.record(request, await owner.snapshot())
            return Self.response(request, text: Self.rss(["https://source.example/a"]))
        }, page: IterationHTTP { request in
            await calls.record(request, await owner.snapshot())
            return Self.response(request, text: "Page", headers: ["Content-Type": "text/plain"])
        })
        let report = try await iterate(owner, next, service: found), after = await owner.snapshot()
        let collection = await owner.collectionSnapshot(), ledger = try await owner.buildEvidenceLedger(limits: .init())
        let expected: [ResearchRun.Resource: Int] = [.rounds: 1, .queries: 1, .searchRequests: 1, .sources: 1, .fetches: 1,
            .evidenceCharacters: collection.sources[0].characterCost + ledger.metadataCharacterCost + report.metadataCharacterCost,
            .planningAttempts: 0, .planningTokens: 0, .synthesisTokens: 0]
        for resource in ResearchRun.Resource.allCases {
            XCTAssertEqual(after.run.usage[resource]! - before.run.usage[resource]!, expected[resource])
        }
        let observations = await calls.observations
        XCTAssertEqual(observations[0].run.usage[.rounds], before.run.usage[.rounds]! + 1)
        XCTAssertEqual(observations[0].run.usage[.queries], before.run.usage[.queries]! + 1)
        XCTAssertEqual(observations[0].run.usage[.searchRequests], before.run.usage[.searchRequests]! + 1)
        XCTAssertEqual(observations[1].run.usage[.fetches], before.run.usage[.fetches]! + 1)
        let cachedLedger = try await owner.buildEvidenceLedger(limits: .init()); XCTAssertEqual(cachedLedger, ledger)
        let cachedReport = try await owner.buildCoverage(limits: .init()); XCTAssertEqual(cachedReport, report)
        let final = await owner.snapshot(); XCTAssertEqual(final, after)
    }

    func testEmptyProposalIsIdempotentNoRoundOrHTTPWork() async throws {
        let owner = try await makeOwner(), next = try await proposal(owner, .init(targets: [])), before = await owner.snapshot()
        let oldReport = try await owner.buildCoverage(limits: .init()), calls = IterationCalls()
        let noHTTP = service(search: IterationHTTP { await calls.record($0); return Self.response($0, status: 500, text: "") })
        let first = try await iterate(owner, next, service: noHTTP), second = try await iterate(owner, next, service: noHTTP)
        XCTAssertEqual(first, oldReport); XCTAssertEqual(second, first)
        let final = await owner.snapshot(); XCTAssertEqual(final, before)
        let requests = await calls.requests; XCTAssertTrue(requests.isEmpty)
    }

    func testReplayWrongDigestAndChangedLimitsAreCorrectableWithoutWork() async throws {
        let owner = try await makeOwner(), next = try await proposal(owner), before = await owner.snapshot()
        do { _ = try await owner.iterate(expectedProposalContextDigest: "wrong", using: service(), collectionLimits: .init()); XCTFail("Wrong digest") }
        catch { XCTAssertEqual(error as? ResearchRefinementProposal.ValidationError, .invalidBinding) }
        do { _ = try await iterate(owner, next, limits: .init(textCharacters: 11_999)); XCTFail("Changed limits") } catch {}
        let unchanged = await owner.snapshot(); XCTAssertEqual(unchanged, before)
        _ = try await iterate(owner, next); let after = await owner.snapshot()
        do { _ = try await iterate(owner, next); XCTFail("Consumed proposal") }
        catch { XCTAssertEqual(error as? ResearchPlanningError, .invalidPhase) }
        let noReplay = await owner.snapshot(); XCTAssertEqual(noReplay, after)
        _ = try await proposal(owner, draft("newer")); let pending = await owner.snapshot()
        do { _ = try await iterate(owner, next); XCTFail("Old handle cannot consume new proposal") }
        catch { XCTAssertEqual(error as? ResearchRefinementProposal.ValidationError, .invalidBinding) }
        let final = await owner.snapshot(); XCTAssertEqual(final, pending)
    }

    func testMissingOwnedProposalOrProjectionRejectedWithoutImplicitWork() async throws {
        let owner = try await makeOwner(), before = await owner.snapshot()
        do { _ = try await owner.iterate(expectedProposalContextDigest: "none", using: service(), collectionLimits: .init()); XCTFail("Proposal required") } catch {}
        let after = await owner.snapshot(); XCTAssertEqual(after, before)
        let noProjection = try await makeOwner(projections: false), state = await noProjection.snapshot()
        do { _ = try await noProjection.iterate(expectedProposalContextDigest: "none", using: service(), collectionLimits: .init()); XCTFail("Owned projections required") } catch {}
        let final = await noProjection.snapshot(); XCTAssertEqual(final, state)
    }

    func testRoundBudgetExhaustionStartsNoHTTPAndCannotRevive() async throws {
        let owner = try await makeOwner(rounds: 1), next = try await proposal(owner), before = await owner.snapshot(), calls = IterationCalls()
        do { _ = try await iterate(owner, next, service: service(search: IterationHTTP { await calls.record($0); return Self.response($0, text: Self.rss([])) })); XCTFail("Round budget") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .budgetExceeded(.rounds)) }
        let failed = await owner.snapshot(); XCTAssertEqual(failed.run.usage, before.run.usage)
        XCTAssertEqual(failed.run.failure, .budgetExhausted)
        let requests = await calls.requests; XCTAssertTrue(requests.isEmpty)
        do { _ = try await iterate(owner, next); XCTFail("Terminal") } catch {}
        let final = await owner.snapshot(); XCTAssertEqual(final, failed)
    }

    func testQueryBudgetChargesRoundButNoQueryAttemptOrHTTPOnDenial() async throws {
        let owner = try await makeOwner(queries: 1), next = try await proposal(owner), before = await owner.snapshot(), calls = IterationCalls()
        do { _ = try await iterate(owner, next, service: service(search: IterationHTTP { await calls.record($0); return Self.response($0, text: Self.rss([])) })); XCTFail("Query budget") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .budgetExceeded(.queries)) }
        let failed = await owner.snapshot()
        XCTAssertEqual(failed.run.usage[.rounds], before.run.usage[.rounds]! + 1)
        XCTAssertEqual(failed.run.usage[.queries], before.run.usage[.queries]); XCTAssertEqual(failed.attemptedQueryIDs, before.attemptedQueryIDs)
        XCTAssertEqual(failed.run.failure, .budgetExhausted)
        let requests = await calls.requests; XCTAssertTrue(requests.isEmpty)
    }

    func testSearchAdmissionDenialRetainsLogicalAttemptButNoHTTP() async throws {
        let owner = try await makeOwner(searches: 1), next = try await proposal(owner), calls = IterationCalls()
        do { _ = try await iterate(owner, next, service: service(search: IterationHTTP { await calls.record($0); return Self.response($0, text: Self.rss([])) })); XCTFail("Search admission") }
        catch { XCTAssertEqual((error as? ResearchHTTPAdmissionError)?.cause as? ResearchRun.ValidationError, .budgetExceeded(.searchRequests)) }
        let failed = await owner.snapshot(), requests = await calls.requests
        XCTAssertEqual(failed.run.usage[.queries], 2); XCTAssertEqual(failed.attemptedQueryIDs, ["query1", "query2"])
        XCTAssertEqual(failed.run.usage[.searchRequests], 1); XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(failed.run.failure, .budgetExhausted)
    }

    func testMetadataVersionsReserveAtomicallyWithoutPartialPublication() async throws {
        let probe = try await makeOwner(), probeProposal = try await proposal(probe), before = await probe.snapshot()
        let nextReport = try await iterate(probe, probeProposal), nextLedger = try await probe.buildEvidenceLedger(limits: .init())
        let required = nextLedger.metadataCharacterCost + nextReport.metadataCharacterCost
        let owner = try await makeOwner(characters: before.run.usage[.evidenceCharacters]! + required - 1)
        let next = try await proposal(owner), initial = await owner.snapshot()
        do { _ = try await iterate(owner, next); XCTFail("Combined metadata budget") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .budgetExceeded(.evidenceCharacters)) }
        let failed = await owner.snapshot(); XCTAssertEqual(failed.run.usage[.evidenceCharacters], initial.run.usage[.evidenceCharacters])
        XCTAssertEqual(failed.run.usage[.rounds], 2); XCTAssertEqual(failed.run.usage[.queries], 2)
        XCTAssertEqual(failed.run.failure, .budgetExhausted)
        do { _ = try await owner.buildEvidenceLedger(limits: .init()); XCTFail("No stale ledger") } catch {}
        do { _ = try await owner.buildCoverage(limits: .init()); XCTFail("No stale coverage") } catch {}
        let final = await owner.snapshot(); XCTAssertEqual(final, failed)
    }

    func testPartialProviderFailureKeepsChargedCollectionAndAttempts() async throws {
        let owner = try await makeOwner(), next = try await proposal(owner, .init(targets: [
            .init(questionID: "question1", gaps: [.noAssociatedSources], queries: ["first followup", "second followup"])]))
        let calls = IterationCalls()
        let failing = service(search: IterationHTTP { request in
            await calls.record(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value
            return Self.response(request, status: query == "first followup" ? 200 : 503,
                text: Self.rss(["https://source.example/a"]))
        })
        do { _ = try await iterate(owner, next, service: failing); XCTFail("Provider failed") } catch {}
        let failed = await owner.snapshot(), collection = await owner.collectionSnapshot()
        XCTAssertEqual(failed.run.failure, .providerUnavailable); XCTAssertEqual(failed.attemptedQueryIDs, ["query1", "query2", "query3"])
        XCTAssertEqual(collection.sources.map(\.id), ["source1"])
        XCTAssertEqual(failed.run.usage[.queries], 3); XCTAssertEqual(failed.run.usage[.searchRequests], 3)
        XCTAssertEqual(failed.run.usage[.fetches], 1); XCTAssertEqual(failed.run.usage[.sources], 1)
        do { _ = try await owner.buildCoverage(limits: .init()); XCTFail("No stale coverage") } catch {}
        let final = await owner.snapshot(); XCTAssertEqual(final, failed)
    }

    func testSourceCeilingSkipsNewFetchButExistingDuplicateLinkStillCharged() async throws {
        let fixed = try ResearchCollectionLimits(maxSources: 1), pages = IterationCalls()
        let initial = service(search: IterationHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) },
            page: IterationHTTP { await pages.record($0); return Self.response($0, status: 500, text: "") })
        let owner = try await makeOwner(initial: initial, collectionLimits: fixed), next = try await proposal(owner, draft(gap: .snippetOnly))
        let mixed = service(search: IterationHTTP { Self.response($0, text: Self.rss(["https://source.example/b", "https://source.example/a"])) },
            page: IterationHTTP { await pages.record($0); return Self.response($0, text: "Page", headers: ["Content-Type": "text/plain"]) })
        _ = try await iterate(owner, next, service: mixed, limits: fixed)
        let collection = await owner.collectionSnapshot(), requests = await pages.requests
        XCTAssertEqual(collection.sources.count, 1); XCTAssertEqual(collection.sources[0].queryIDs, ["query1", "query2"])
        XCTAssertEqual(requests.count, 1)
    }

    func testOverlapCannotAdoptProposalOrBuildStaleProjection() async throws {
        let owner = try await makeOwner(), next = try await proposal(owner), gate = IterationGate()
        let held = service(search: IterationHTTP { await gate.hold(); return Self.response($0, text: Self.rss([])) })
        let task = Task { try await owner.iterate(expectedProposalContextDigest: next.contextDigest, using: held, collectionLimits: .init()) }
        await gate.waitForEntry(); let before = await owner.snapshot()
        do { _ = try await iterate(owner, next); XCTFail("Busy") }
        catch { XCTAssertEqual(error as? ResearchPlanningError, .operationInProgress) }
        do { _ = try await owner.buildEvidenceLedger(limits: .init()); XCTFail("Busy ledger") }
        catch { XCTAssertEqual(error as? ResearchPlanningError, .operationInProgress) }
        let unchanged = await owner.snapshot(); XCTAssertEqual(unchanged, before)
        await gate.release(); _ = try await task.value
        let final = await owner.snapshot(); XCTAssertEqual(final.run.phase, .evaluating)
    }

    func testCancellationRejectsLatePageResponseAndPreservesTerminalAccounting() async throws {
        let owner = try await makeOwner(), next = try await proposal(owner), gate = IterationGate()
        let held = service(search: IterationHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) },
            page: IterationHTTP { await gate.hold(); return Self.response($0, text: "Late page", headers: ["Content-Type": "text/plain"]) })
        let task = Task { try await owner.iterate(expectedProposalContextDigest: next.contextDigest, using: held, collectionLimits: .init()) }
        await gate.waitForEntry(); try await owner.cancel(); let terminal = await owner.snapshot()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled") } catch {}
        let final = await owner.snapshot(), collection = await owner.collectionSnapshot()
        XCTAssertEqual(final, terminal); XCTAssertEqual(final.run.phase, .cancelled)
        XCTAssertEqual(final.run.usage[.fetches], 1); XCTAssertTrue(collection.sources.isEmpty)
    }

    func testOriginalDeadlineRejectsLateSearchResponseWithoutExtraFetchOrPublication() async throws {
        let clock = PlanningTestClock(Self.start), owner = try await makeOwner(clock: clock), next = try await proposal(owner), gate = IterationGate()
        let held = service(search: IterationHTTP { await gate.hold(); return Self.response($0, text: Self.rss(["https://source.example/a"])) })
        let task = Task { try await owner.iterate(expectedProposalContextDigest: next.contextDigest, using: held, collectionLimits: .init()) }
        await gate.waitForEntry(); let before = await owner.snapshot()
        clock.advance(to: Self.start.addingTimeInterval(100)); await gate.release()
        do { _ = try await task.value; XCTFail("Original deadline") } catch {}
        let failed = await owner.snapshot(), collection = await owner.collectionSnapshot()
        XCTAssertEqual(failed.run.failure, .budgetExhausted); XCTAssertEqual(failed.run.usage, before.run.usage)
        XCTAssertTrue(collection.sources.isEmpty)
        do { _ = try await iterate(owner, next); XCTFail("Terminal") } catch {}
        let final = await owner.snapshot(); XCTAssertEqual(final, failed)
    }

    func testAppendPlanByteAndQueryTextLimitsFailBeforeRoundOrHTTPMutation() async throws {
        let owner = try await makeOwner(planningLimits: .init(planBytes: 750)), before = await owner.snapshot()
        let oversize = draft(String(repeating: "x", count: 500)), pure = try await pureProposal(owner, oversize)
        XCTAssertThrowsError(try XCTUnwrap(before.plan).appending(pure, for: before.run))
        do { _ = try await proposal(owner, oversize); XCTFail("Bounded extended plan before caching") }
        catch { XCTAssertEqual(error as? ResearchPlan.ValidationError, .oversizedPlan) }
        let unchanged = await owner.snapshot(); XCTAssertEqual(unchanged, before)
        let corrected = try await proposal(owner, draft("short")); _ = try await iterate(owner, corrected)
        let short = try await makeOwner(planningLimits: .init(queryCharacters: 3)), shortBefore = await short.snapshot()
        let longProposal = try await pureProposal(short, draft("long"))
        XCTAssertThrowsError(try XCTUnwrap(shortBefore.plan).appending(longProposal, for: shortBefore.run))
        do { _ = try await proposal(short, draft("long")); XCTFail("Host query text limit before caching") }
        catch { XCTAssertEqual(error as? ResearchPlan.ValidationError, .invalidQueries) }
        let final = await short.snapshot(); XCTAssertEqual(final, shortBefore)
        let executable = try await proposal(short, draft("new")); _ = try await iterate(short, executable)
    }

    func testCachedCollectRejectsChangedLimitsAcrossAllRounds() async throws {
        let owner = try await makeOwner(), before = await owner.snapshot()
        do { _ = try await owner.collect(using: service(), limits: .init(resultsPerQuery: 5)); XCTFail("Pinned limits") }
        catch { XCTAssertEqual(error as? ResearchRefinementProposal.ValidationError, .invalidBinding) }
        let unchanged = await owner.snapshot(); XCTAssertEqual(unchanged, before)
        let next = try await proposal(owner); _ = try await iterate(owner, next); let after = await owner.snapshot()
        do { _ = try await owner.collect(using: service(), limits: .init(urlBytes: 16_383)); XCTFail("Pinned across rounds") } catch {}
        let final = await owner.snapshot(); XCTAssertEqual(final, after)
    }

    func testPureAppendRejectsWrongRunPriorTextAndBaselineAssociationForgery() async throws {
        let owner = try await makeOwner(questions: ["one", "one"]), next = try await proposal(owner)
        let state = await owner.snapshot(), plan = try XCTUnwrap(state.plan)
        let unrelated = try ResearchRun(conversationID: state.run.conversationID, query: state.run.query,
            budget: state.run.budget, now: Self.start)
        XCTAssertThrowsError(try plan.appending(next, for: unrelated))
        func modified(_ change: (inout [String: Any]) -> Void) throws -> ResearchRefinementProposal {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(next)) as? [String: Any])
            change(&object)
            return try JSONDecoder().decode(ResearchRefinementProposal.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let repeated = try modified {
            var rows = $0["queries"] as! [[String: Any]]; rows[0]["text"] = "one"; $0["queries"] = rows
        }
        XCTAssertThrowsError(try plan.appending(repeated, for: state.run))
        let forged = try modified { $0["baselineAssociationCount"] = 1 }
        XCTAssertThrowsError(try plan.appending(forged, for: state.run))
        let extended = try plan.appending(next, for: state.run)
        XCTAssertEqual(extended.subquestions[0].queryIDs, ["query1", "query2"])
        XCTAssertEqual(extended.subquestions[1].queryIDs, ["query1"])
    }

    func testProjectionLimitFailureKeepsPartialSourcesAndDeadlineTakesPrecedence() async throws {
        let initial = service(search: IterationHTTP { Self.response($0, text: Self.rss(["https://source.example/a"])) },
            page: IterationHTTP { Self.response($0, status: 500, text: "") })
        let found = service(search: IterationHTTP { Self.response($0, text: Self.rss(["https://source.example/b"])) })
        let owner = try await makeOwner(initial: initial, evidenceLimits: .init(sources: 1))
        let next = try await proposal(owner, draft(gap: .snippetOnly)), before = await owner.snapshot()
        do { _ = try await iterate(owner, next, service: found); XCTFail("Fixed projection limit") }
        catch { XCTAssertEqual(error as? ResearchEvidenceLedger.ValidationError, .invalidCollection) }
        let failed = await owner.snapshot(), collection = await owner.collectionSnapshot()
        XCTAssertEqual(failed.run.failure, .invalidResponse); XCTAssertEqual(collection.sources.count, 2)
        XCTAssertEqual(failed.run.usage[.evidenceCharacters]! - before.run.usage[.evidenceCharacters]!, collection.sources[1].characterCost)
        do { _ = try await owner.buildEvidenceLedger(limits: .init()); XCTFail("Cannot widen terminal projection") } catch {}
        let clock = IterationExpiryClock(Self.start)
        let expiredOwner = try await makeOwner(initial: initial, evidenceLimits: .init(sources: 1), injectedClock: clock.injected)
        let expiredProposal = try await proposal(expiredOwner, draft(gap: .snippetOnly))
        let crossing = service(search: IterationHTTP { Self.response($0, text: Self.rss(["https://source.example/b"])) },
            page: IterationHTTP { request in
                clock.expireAfter(reads: 3)
                return Self.response(request, text: "Page", headers: ["Content-Type": "text/plain"])
            })
        do { _ = try await iterate(expiredOwner, expiredProposal, service: crossing); XCTFail("Deadline after projection error") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .wallTimeExceeded) }
        let expired = await expiredOwner.snapshot(); XCTAssertEqual(expired.run.failure, .budgetExhausted)
        let partial = await expiredOwner.collectionSnapshot(); XCTAssertEqual(partial.sources.count, 2)
    }

    func testNewSourceAppendPreservesOldEvidencePrefixAndInheritedSegmentLimit() async throws {
        let initial = service(search: IterationHTTP {
            Self.response($0, text: "<rss><channel><item><title>Old</title><link>https://source.example/a</link><description>Sn</description></item></channel></rss>")
        }, page: IterationHTTP { Self.response($0, status: 500, text: "") })
        let fixedEvidence = try ResearchEvidenceLimits(entries: 2, segmentCharacters: 2)
        let owner = try await makeOwner(initial: initial, evidenceLimits: fixedEvidence)
        let oldCollection = await owner.collectionSnapshot(), oldLedger = try await owner.buildEvidenceLedger(limits: fixedEvidence)
        let next = try await proposal(owner, draft(gap: .snippetOnly))
        let found = service(search: IterationHTTP { Self.response($0, text: Self.rss(["https://source.example/b"])) })
        let report = try await iterate(owner, next, service: found), collection = await owner.collectionSnapshot()
        let ledger = try await owner.buildEvidenceLedger(limits: fixedEvidence)
        XCTAssertEqual(collection.sources.map(\.id), ["source1", "source2"])
        XCTAssertEqual(collection.sources[0], oldCollection.sources[0])
        XCTAssertEqual(Array(ledger.entries.prefix(oldLedger.entries.count)), oldLedger.entries)
        XCTAssertEqual(ledger.entries.map(\.id), ["evidence1", "evidence2"])
        XCTAssertEqual(ledger.entries[1].text, "Pa"); XCTAssertEqual(ledger.entries[1].characterOffset, 0)
        XCTAssertFalse(ledger.sources[0].ledgerTruncated); XCTAssertTrue(ledger.sources[1].ledgerTruncated)
        XCTAssertEqual(report.questions[0].availability, .mixedEntries)
        XCTAssertEqual(report.questions[0].gaps, [.ledgerTruncated])
    }
}
