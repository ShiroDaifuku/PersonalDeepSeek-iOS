import Foundation
import XCTest
@testable import PersonalDeepSeek

private struct RefinementHTTP: ResearchHTTPFetching {
    func data(for request: URLRequest) async throws -> ResearchHTTPResponse {
        .init(data: Data("<rss><channel></channel></rss>".utf8), url: request.url!, statusCode: 200)
    }
}

private final class RefinementExpiryClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base: PlanningTestClock
    private let start: Date
    private var armed = false
    private var reads = 0
    init(_ start: Date) { self.start = start; base = PlanningTestClock(start) }
    func expireAfterNextRead() { lock.withLock { armed = true; reads = 0 } }
    private func now() -> Date {
        lock.withLock {
            guard armed else { return start }
            reads += 1
            return reads == 1 ? start : start.addingTimeInterval(100)
        }
    }
    var injected: ResearchPlanningClock { .init(now: { self.now() }, sleepUntil: base.injected.sleepUntil) }
}

final class ResearchRefinementTests: XCTestCase {
    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private struct Context {
        let run: ResearchRun
        let plan: ResearchPlan
        let collection: ResearchCollectionSnapshot
        let ledger: ResearchEvidenceLedger
        let coverage: ResearchCoverageReport
    }
    private func makeRun(characters: Int = 100_000) throws -> ResearchRun {
        try .init(conversationID: UUID(), query: "Research question", budget: .init(rounds: 2, queries: 10,
            sources: 10, fetches: 10, evidenceCharacters: characters, synthesisTokens: 100, wallSeconds: 100), now: Self.start)
    }
    private func planDraft() -> ResearchPlannerDraft {
        .init(subquestions: [.init(question: "First", queries: ["Café query"]),
                            .init(question: "Second", queries: ["second query"]),
                            .init(question: "Third", queries: ["third query"])])
    }
    private func context(sources: [ResearchCollectedSource] = [], planningLimits: ResearchPlanningLimits = try! .init()) throws -> Context {
        let run = try makeRun(), plan = try ResearchPlan(draft: planDraft(), run: run, limits: planningLimits)
        let collection = ResearchCollectionSnapshot(runID: run.id, conversationID: run.conversationID, sources: sources)
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: .init())
        let coverage = try ResearchCoverageReport.build(plan: plan, collection: collection, ledger: ledger,
            evidenceLimits: ledger.limits, limits: .init())
        return Context(run: run, plan: plan, collection: collection, ledger: ledger, coverage: coverage)
    }
    private func draft(_ query: String = "new query", question: String = "question1",
                       gaps: [ResearchCoverageReport.Gap] = [.noAssociatedSources]) -> ResearchRefinementDraft {
        .init(targets: [.init(questionID: question, gaps: gaps, queries: [query])])
    }
    private func build(_ draft: ResearchRefinementDraft, _ c: Context,
                       attempts: Set<String> = ["query1", "query2", "query3"],
                       limits: ResearchRefinementLimits = try! .init()) throws -> ResearchRefinementProposal {
        try .build(draft: draft, run: c.run, plan: c.plan, planningLimits: c.plan.limits, collection: c.collection,
            ledger: c.ledger, evidenceLimits: c.ledger.limits, coverage: c.coverage, coverageLimits: c.coverage.limits,
            attemptedQueryIDs: attempts, limits: limits)
    }
    private func decode(_ data: Data, draft: ResearchRefinementDraft, context c: Context,
                        attempts: Set<String> = ["query1", "query2", "query3"],
                        limits: ResearchRefinementLimits = try! .init()) throws -> ResearchRefinementProposal {
        try .decode(data, draft: draft, run: c.run, plan: c.plan, planningLimits: c.plan.limits, collection: c.collection,
            ledger: c.ledger, evidenceLimits: c.ledger.limits, coverage: c.coverage, coverageLimits: c.coverage.limits,
            attemptedQueryIDs: attempts, limits: limits)
    }
    private func edited<T: Encodable>(_ value: T, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    func testDistinctCanonicalQueriesHaveHostIDsAndExistingGapTargets() throws {
        let c = try context()
        let input = ResearchRefinementDraft(targets: [
            .init(questionID: "question2", gaps: [.noRetainedEntries, .noAssociatedSources], queries: [" New\nquery "]),
            .init(questionID: "question1", gaps: [.noAssociatedSources], queries: ["other"])])
        let value = try build(input, c)
        XCTAssertEqual(value.queries.map(\.id), ["query4", "query5"])
        XCTAssertEqual(value.queries.map(\.text), ["New query", "other"])
        XCTAssertEqual(value.targets.map(\.questionID), ["question1", "question2"])
        XCTAssertEqual(value.targets[0].queryIDs, ["query5"])
        XCTAssertEqual(value.targets[1].gaps, [.noAssociatedSources, .noRetainedEntries])
        XCTAssertEqual(value.attemptedQueryIDs, ["query1", "query2", "query3"])
        XCTAssertEqual(value, try build(input, c))
    }

    func testPlannedQueriesRejectedRegardlessOfAttemptAndUnicodeSpelling() throws {
        let c = try context()
        let attemptSets: [Set<String>] = [[], ["query1"]]
        for attempts in attemptSets {
            XCTAssertThrowsError(try build(draft(" CAFE\u{301}\tQUERY "), c, attempts: attempts))
        }
        XCTAssertThrowsError(try build(draft("new"), c, attempts: ["query999"]))
        let shared = ResearchRefinementDraft(targets: [.init(questionID: "question1", gaps: [.noAssociatedSources],
            queries: ["cafe\u{301} new", "CAFÉ NEW"])])
        XCTAssertThrowsError(try build(shared, c))
        let across = ResearchRefinementDraft(targets: [draft("new").targets[0], draft("NEW", question: "question2").targets[0]])
        XCTAssertThrowsError(try build(across, c))
    }

    func testEmptyDraftExplicitlyCreatesNoExecutionWork() throws {
        let c = try context(), input = ResearchRefinementDraft(targets: [])
        let proposal = try build(input, c)
        XCTAssertTrue(proposal.queries.isEmpty); XCTAssertTrue(proposal.targets.isEmpty)
        XCTAssertEqual(try decode(JSONEncoder().encode(proposal), draft: input, context: c), proposal)
        XCTAssertEqual(proposal.metadataCharacterCost, 64 + "query1query2query3".count)
    }

    func testUnknownCoveredDuplicateAndFalseGapTargetsReject() throws {
        let source = ResearchCollectedSource(id: "source1", requestedURLKey: "https://source.example/a", queryIDs: ["query1"],
            provider: .bingRSS, source: .init(title: "Page", url: URL(string: "https://source.example/a")!, snippet: "", pageText: "Page"), pageFetched: true)
        let covered = try context(sources: [source]), empty = try context()
        XCTAssertThrowsError(try build(draft(), covered))
        XCTAssertThrowsError(try build(draft(question: "question4"), empty))
        XCTAssertThrowsError(try build(draft(gaps: [.snippetOnly]), empty))
        XCTAssertThrowsError(try build(draft(gaps: []), empty))
        XCTAssertThrowsError(try build(draft(gaps: [.noAssociatedSources, .noAssociatedSources]), empty))
        XCTAssertThrowsError(try build(.init(targets: [draft().targets[0], draft().targets[0]]), empty))
    }

    func testDraftAndProposalTextCountsBytesAndGlobalCapacityBounded() throws {
        let c = try context()
        XCTAssertThrowsError(try build(draft("a\u{202E}b"), c))
        XCTAssertThrowsError(try build(draft("  \n"), c))
        XCTAssertThrowsError(try build(draft("long"), c, limits: .init(queryCharacters: 3)))
        XCTAssertThrowsError(try build(draft("éé"), c, limits: .init(queryBytes: 3)))
        XCTAssertThrowsError(try build(draft("a" + String(repeating: "\u{301}", count: 30)), c, limits: .init(queryBytes: 20)))
        XCTAssertThrowsError(try build(draft(), c, limits: .init(draftBytes: 8)))
        XCTAssertThrowsError(try build(draft(), c, limits: .init(proposalBytes: 8)))
        let many = ResearchRefinementDraft(targets: [.init(questionID: "question1", gaps: [.noAssociatedSources], queries: ["a", "b"])])
        XCTAssertThrowsError(try build(many, c, limits: .init(queries: 1)))
        let full = try context(planningLimits: .init(queries: 3))
        XCTAssertThrowsError(try build(draft(), full))
        XCTAssertNoThrow(try build(.init(targets: []), full))
        XCTAssertThrowsError(try ResearchRefinementLimits(queries: 129))
        XCTAssertThrowsError(try ResearchRefinementLimits(queryBytes: 8_001))
    }

    func testSharedBaselineAssociationCapacityIsNotUniqueQueryCapacity() throws {
        let run = try makeRun(), limits = try ResearchPlanningLimits(queries: 3)
        let input = ResearchPlannerDraft(subquestions: [.init(question: "First", queries: ["shared"]),
            .init(question: "Second", queries: ["shared"]), .init(question: "Third", queries: ["shared"])])
        let plan = try ResearchPlan(draft: input, run: run, limits: limits)
        XCTAssertEqual(plan.queries.count, 1)
        let collection = ResearchCollectionSnapshot(runID: run.id, conversationID: run.conversationID, sources: [])
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: .init())
        let report = try ResearchCoverageReport.build(plan: plan, collection: collection, ledger: ledger,
            evidenceLimits: ledger.limits, limits: .init())
        XCTAssertThrowsError(try ResearchRefinementProposal.build(draft: draft(), run: run, plan: plan,
            planningLimits: limits, collection: collection, ledger: ledger, evidenceLimits: ledger.limits,
            coverage: report, coverageLimits: report.limits, attemptedQueryIDs: ["query1"], limits: .init()))
    }

    func testRawDataBoundCheckedBeforeDecodeAndVersionLimitCorruptionRejected() throws {
        let c = try context(), value = try build(draft(), c)
        XCTAssertThrowsError(try ResearchRefinementDraft.decode(Data(repeating: 32, count: 100), limits: .init(draftBytes: 99)))
        XCTAssertThrowsError(try decode(Data(repeating: 32, count: 100), draft: draft(), context: c, limits: .init(proposalBytes: 99)))
        for version in [0, 2] {
            XCTAssertThrowsError(try JSONDecoder().decode(ResearchRefinementProposal.self, from: edited(value) { $0["version"] = version }))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ResearchRefinementProposal.self, from: edited(value) {
            var limits = $0["limits"] as! [String: Any]; limits["targets"] = 33; $0["limits"] = limits
        }))
    }

    func testGenericDecoderRejectsDanglingDuplicateIDsGapsAndInvalidDigest() throws {
        let c = try context(), value = try build(draft(), c)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["contextDigest"] = "invalid" },
            { $0["attemptedQueryIDs"] = ["query2", "query1"] },
            { $0["attemptedQueryIDs"] = ["query1", "query1"] },
            { $0["baselineQueryCount"] = 129 },
            { $0["queryCapacity"] = 3 },
            { var rows = $0["queries"] as! [[String: Any]]; rows[0]["id"] = "query3"; $0["queries"] = rows },
            { var rows = $0["queries"] as! [[String: Any]]; rows[0]["text"] = " new query "; $0["queries"] = rows },
            { var rows = $0["targets"] as! [[String: Any]]; rows[0]["queryIDs"] = ["query5"]; $0["targets"] = rows },
            { var rows = $0["targets"] as! [[String: Any]]; rows[0]["gaps"] = ["noAssociatedSources", "noAssociatedSources"]; $0["targets"] = rows },
            { var rows = $0["targets"] as! [[String: Any]]; rows[0]["questionID"] = "question4"; $0["targets"] = rows }
        ]
        for mutation in mutations {
            XCTAssertThrowsError(try JSONDecoder().decode(ResearchRefinementProposal.self, from: edited(value, mutation)))
        }
    }

    func testHostDecodeBindsDraftAttemptSetLimitsAndRunContext() throws {
        let c = try context(), input = draft(), value = try build(input, c), data = try JSONEncoder().encode(value)
        XCTAssertEqual(value, try decode(data, draft: input, context: c))
        XCTAssertThrowsError(try decode(data, draft: draft("different"), context: c))
        XCTAssertThrowsError(try decode(data, draft: input, context: c, attempts: ["query1"]))
        XCTAssertThrowsError(try decode(data, draft: input, context: c, limits: .init(targets: 7)))
        let changed = try JSONDecoder().decode(ResearchRun.self, from: edited(c.run) { $0["query"] = "Other question" })
        XCTAssertThrowsError(try ResearchRefinementProposal.build(draft: input, run: changed, plan: c.plan,
            planningLimits: c.plan.limits, collection: c.collection, ledger: c.ledger, evidenceLimits: c.ledger.limits,
            coverage: c.coverage, coverageLimits: c.coverage.limits, attemptedQueryIDs: [], limits: .init()))
        let tampered = try edited(value) { $0["runID"] = UUID().uuidString }
        _ = try JSONDecoder().decode(ResearchRefinementProposal.self, from: tampered)
        XCTAssertThrowsError(try decode(tampered, draft: input, context: c))
    }

    func testCoverageAndLedgerFullProjectionMustMatchBeforeProposalUse() throws {
        let c = try context(), coverageData = try edited(c.coverage) { $0["ledgerContextDigest"] = String(repeating: "0", count: 64) }
        let forged = try JSONDecoder().decode(ResearchCoverageReport.self, from: coverageData)
        XCTAssertThrowsError(try ResearchRefinementProposal.build(draft: draft(), run: c.run, plan: c.plan,
            planningLimits: c.plan.limits, collection: c.collection, ledger: c.ledger, evidenceLimits: c.ledger.limits,
            coverage: forged, coverageLimits: forged.limits, attemptedQueryIDs: [], limits: .init()))
        let ledgerData = try edited(c.ledger) { $0["collectionContextDigest"] = String(repeating: "0", count: 64) }
        let forgedLedger = try JSONDecoder().decode(ResearchEvidenceLedger.self, from: ledgerData)
        XCTAssertThrowsError(try ResearchRefinementProposal.build(draft: draft(), run: c.run, plan: c.plan,
            planningLimits: c.plan.limits, collection: c.collection, ledger: forgedLedger, evidenceLimits: c.ledger.limits,
            coverage: c.coverage, coverageLimits: c.coverage.limits, attemptedQueryIDs: [], limits: .init()))
    }

    func testStableContextIncludesCreationAndEveryBudgetButIgnoresDictionaryOrder() throws {
        let c = try context(), expected = try build(draft(), c)
        func proposal(for run: ResearchRun) throws -> ResearchRefinementProposal {
            try build(draft(), Context(run: run, plan: c.plan, collection: c.collection, ledger: c.ledger, coverage: c.coverage))
        }
        let earlier = try JSONDecoder().decode(ResearchRun.self, from: edited(c.run) { $0["createdAt"] = 999 })
        XCTAssertNotEqual(expected.contextDigest, try proposal(for: earlier).contextDigest)
        let longer = try JSONDecoder().decode(ResearchRun.self, from: edited(c.run) {
            var budget = $0["budget"] as! [String: Any]; budget["wallSeconds"] = 101; $0["budget"] = budget
        })
        XCTAssertNotEqual(expected.contextDigest, try proposal(for: longer).contextDigest)
        for resource in ResearchRun.Resource.allCases {
            let changed = try JSONDecoder().decode(ResearchRun.self, from: edited(c.run) {
                var budget = $0["budget"] as! [String: Any], rows = budget["limits"] as! [Any]
                for index in stride(from: 0, to: rows.count, by: 2) where rows[index] as? String == resource.rawValue {
                    rows[index + 1] = (rows[index + 1] as! Int) + 1
                }
                budget["limits"] = rows; $0["budget"] = budget
            })
            XCTAssertNotEqual(expected.contextDigest, try proposal(for: changed).contextDigest)
        }
        let reversed = try JSONDecoder().decode(ResearchRun.self, from: edited(c.run) {
            var budget = $0["budget"] as! [String: Any]
            let rows = budget["limits"] as! [Any]
            var reordered: [Any] = []
            for index in stride(from: rows.count - 2, through: 0, by: -2) {
                reordered.append(rows[index]); reordered.append(rows[index + 1])
            }
            budget["limits"] = reordered; $0["budget"] = budget
        })
        XCTAssertEqual(expected, try proposal(for: reversed))
    }

    func testUnselectedCollectionTextChangeCannotReuseProposalWithSameIDs() throws {
        let source = ResearchCollectedSource(id: "source1", requestedURLKey: "https://source.example/a", queryIDs: ["query1"],
            provider: .bingRSS, source: .init(title: "Title", url: URL(string: "https://source.example/a")!, snippet: "Unused", pageText: "Page"), pageFetched: true)
        let c = try context(sources: [source]), input = draft(question: "question2")
        let original = try build(input, c), data = try JSONEncoder().encode(original)
        let changedSource = ResearchCollectedSource(id: source.id, requestedURLKey: source.requestedURLKey,
            queryIDs: source.queryIDs, provider: source.provider,
            source: .init(id: source.source.id, title: source.source.title, url: source.source.url, snippet: "Changed unused", pageText: "Page"), pageFetched: true)
        let collection = ResearchCollectionSnapshot(runID: c.run.id, conversationID: c.run.conversationID, sources: [changedSource])
        let ledger = try ResearchEvidenceLedger.build(plan: c.plan, collection: collection, limits: c.ledger.limits)
        XCTAssertEqual(ledger.entries, c.ledger.entries)
        let coverage = try ResearchCoverageReport.build(plan: c.plan, collection: collection, ledger: ledger,
            evidenceLimits: ledger.limits, limits: c.coverage.limits)
        let changed = Context(run: c.run, plan: c.plan, collection: collection, ledger: ledger, coverage: coverage)
        XCTAssertThrowsError(try decode(data, draft: input, context: changed))
    }

    private func makeOwner(characters: Int = 100_000, clock: PlanningTestClock? = nil,
                           coverage: Bool = true, injectedClock: ResearchPlanningClock? = nil) async throws -> ResearchPlanningCoordinator {
        let owner = ResearchPlanningCoordinator(run: try makeRun(characters: characters), limits: try .init(),
            planner: FixtureResearchPlanner(fixture: planDraft()),
            clock: injectedClock ?? clock?.injected ?? PlanningTestClock(Self.start).injected)
        _ = try await owner.plan()
        let service = LocalResearchService(accountedSearchFetcher: RefinementHTTP(), searchAPIKey: { nil })
        _ = try await owner.collect(using: service, limits: .init())
        _ = try await owner.buildEvidenceLedger(limits: .init())
        if coverage { _ = try await owner.buildCoverage(limits: .init()) }
        return owner
    }

    func testCoordinatorRequiresOwnedCoverageWithoutImplicitWork() async throws {
        let owner = try await makeOwner(coverage: false), before = await owner.snapshot()
        do { _ = try await owner.buildRefinement(draft: draft(), limits: .init()); XCTFail("Owned coverage required") }
        catch { XCTAssertEqual(error as? ResearchPlanningError, .invalidPhase) }
        let after = await owner.snapshot(); XCTAssertEqual(before, after)
    }

    func testCoordinatorOnlyMetadataIsChargedOnceAndAcceptedStateRemainsIntact() async throws {
        let owner = try await makeOwner(), before = await owner.snapshot(), collection = await owner.collectionSnapshot()
        let ledger = try await owner.buildEvidenceLedger(limits: .init()), report = try await owner.buildCoverage(limits: .init())
        let proposal = try await owner.buildRefinement(draft: draft(), limits: .init()), after = await owner.snapshot()
        XCTAssertEqual(proposal.metadataCharacterCost, 64 + "query1query2query3query4new queryquestion1noAssociatedSourcesquery4".count)
        XCTAssertEqual(after.run.usage[.evidenceCharacters]! - before.run.usage[.evidenceCharacters]!, proposal.metadataCharacterCost)
        for resource in ResearchRun.Resource.allCases where resource != .evidenceCharacters {
            XCTAssertEqual(after.run.usage[resource], before.run.usage[resource])
        }
        XCTAssertEqual(after.plan, before.plan); XCTAssertEqual(after.attemptedQueryIDs, before.attemptedQueryIDs)
        XCTAssertEqual(after.run.phase, .evaluating)
        let finalCollection = await owner.collectionSnapshot(); XCTAssertEqual(finalCollection.sources.count, collection.sources.count)
        let finalLedger = try await owner.buildEvidenceLedger(limits: .init()); XCTAssertEqual(finalLedger, ledger)
        let finalReport = try await owner.buildCoverage(limits: .init()); XCTAssertEqual(finalReport, report)
        let repeated = try await owner.buildRefinement(draft: draft(), limits: .init()); XCTAssertEqual(repeated, proposal)
        let final = await owner.snapshot(); XCTAssertEqual(final, after)
        XCTAssertEqual(ResearchRun.checkpointVersion, 3)
        let currentContext = Context(run: after.run, plan: try XCTUnwrap(after.plan), collection: collection, ledger: ledger, coverage: report)
        XCTAssertEqual(try decode(JSONEncoder().encode(proposal), draft: draft(), context: currentContext), proposal)
    }

    func testInvalidOfflineDraftCanBeCorrectedAndCacheConflictDoesNotMutate() async throws {
        let owner = try await makeOwner(), before = await owner.snapshot()
        do { _ = try await owner.buildRefinement(draft: draft("second query"), limits: .init()); XCTFail("Old query") } catch {}
        let unchanged = await owner.snapshot(); XCTAssertEqual(unchanged, before)
        _ = try await owner.buildRefinement(draft: draft(), limits: .init()); let accepted = await owner.snapshot()
        do { _ = try await owner.buildRefinement(draft: draft("changed"), limits: .init()); XCTFail("Fixed proposal") }
        catch { XCTAssertEqual(error as? ResearchRefinementProposal.ValidationError, .invalidBinding) }
        do { _ = try await owner.buildRefinement(draft: draft(" new query "), limits: .init()); XCTFail("Raw draft identity is fixed") } catch {}
        do { _ = try await owner.buildRefinement(draft: draft(), limits: .init(targets: 7)); XCTFail("Fixed limits") } catch {}
        let final = await owner.snapshot(); XCTAssertEqual(final, accepted)
    }

    func testBudgetFailureAtomicAndCannotReviveOrRefund() async throws {
        let probe = try await makeOwner(), before = await probe.snapshot()
        let required = try await probe.buildRefinement(draft: draft(), limits: .init()).metadataCharacterCost
        let owner = try await makeOwner(characters: before.run.usage[.evidenceCharacters]! + required - 1)
        let initial = await owner.snapshot()
        do { _ = try await owner.buildRefinement(draft: draft(), limits: .init()); XCTFail("Budget") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .budgetExceeded(.evidenceCharacters)) }
        let failed = await owner.snapshot(); XCTAssertEqual(failed.run.usage, initial.run.usage)
        XCTAssertEqual(failed.run.failure, .budgetExhausted)
        do { _ = try await owner.buildRefinement(draft: draft(), limits: .init()); XCTFail("Terminal") } catch {}
        let final = await owner.snapshot(); XCTAssertEqual(final, failed)
    }

    func testOriginalDeadlineAndCancellationApplyToCachedProposal() async throws {
        let clock = PlanningTestClock(Self.start), owner = try await makeOwner(clock: clock)
        _ = try await owner.buildRefinement(draft: draft(), limits: .init()); let before = await owner.snapshot()
        clock.advance(to: Self.start.addingTimeInterval(100))
        do { _ = try await owner.buildRefinement(draft: draft(), limits: .init()); XCTFail("Deadline") } catch {}
        let expired = await owner.snapshot(); XCTAssertEqual(expired.run.failure, .budgetExhausted)
        XCTAssertEqual(expired.run.usage, before.run.usage)
        let cancelled = try await makeOwner(); _ = try await cancelled.buildRefinement(draft: draft(), limits: .init())
        try await cancelled.cancel(); let terminal = await cancelled.snapshot()
        do { _ = try await cancelled.buildRefinement(draft: draft(), limits: .init()); XCTFail("Cancelled") } catch {}
        let final = await cancelled.snapshot(); XCTAssertEqual(final, terminal)
    }

    func testCorrectableDraftErrorCannotHideDeadlineCrossedDuringValidation() async throws {
        let clock = RefinementExpiryClock(Self.start), owner = try await makeOwner(injectedClock: clock.injected)
        let before = await owner.snapshot()
        clock.expireAfterNextRead()
        do { _ = try await owner.buildRefinement(draft: draft("second query"), limits: .init()); XCTFail("Expired validation") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .wallTimeExceeded) }
        let expired = await owner.snapshot()
        XCTAssertEqual(expired.run.failure, .budgetExhausted); XCTAssertEqual(expired.run.usage, before.run.usage)
        do { _ = try await owner.buildRefinement(draft: draft(), limits: .init()); XCTFail("Cannot revive") } catch {}
        let final = await owner.snapshot(); XCTAssertEqual(final, expired)
    }
}
