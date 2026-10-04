import Foundation
import XCTest
@testable import PersonalDeepSeek

private struct CoverageHTTP: ResearchHTTPFetching {
    let action: @Sendable (URLRequest) async throws -> ResearchHTTPResponse
    func data(for request: URLRequest) async throws -> ResearchHTTPResponse { try await action(request) }
}
private struct CoverageDNS: ResearchDNSResolving {
    func addresses(for host: String) async throws -> [String] { ["8.8.8.8"] }
}

final class ResearchCoverageTests: XCTestCase {
    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private func makeRun(characters: Int = 100_000) throws -> ResearchRun {
        try .init(conversationID: UUID(), query: "Question", budget: .init(rounds: 2, queries: 10,
            sources: 10, fetches: 10, evidenceCharacters: characters, synthesisTokens: 100, wallSeconds: 100), now: Self.start)
    }
    private func draft() -> ResearchPlannerDraft {
        .init(subquestions: [.init(question: "First", queries: ["shared"]),
                            .init(question: "Second", queries: ["shared", "other"]),
                            .init(question: "Third", queries: ["missing"])])
    }
    private func context(text: String = "Page", snippet: String = "Snippet") throws -> (ResearchPlan, ResearchCollectionSnapshot) {
        let run = try makeRun(), plan = try ResearchPlan(draft: draft(), run: run, limits: .init())
        let sources = [ResearchCollectedSource(id: "source1", requestedURLKey: "https://source.example/a",
            queryIDs: ["query1"], provider: .brave,
            source: .init(title: "First", url: URL(string: "https://source.example/final")!, snippet: "unused", pageText: text), pageFetched: true),
            ResearchCollectedSource(id: "source2", requestedURLKey: "https://source.example/b",
            queryIDs: ["query2"], provider: .bingRSS,
            source: .init(title: "Second", url: URL(string: "https://source.example/final")!, snippet: snippet, pageText: ""), pageFetched: false)]
        return (plan, .init(runID: run.id, conversationID: run.conversationID, sources: sources))
    }
    private func report(_ plan: ResearchPlan, _ collection: ResearchCollectionSnapshot,
                        evidenceLimits: ResearchEvidenceLimits = try! .init(),
                        limits: ResearchCoverageLimits = try! .init()) throws -> ResearchCoverageReport {
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: evidenceLimits)
        return try .build(plan: plan, collection: collection, ledger: ledger, evidenceLimits: evidenceLimits, limits: limits)
    }
    private func edited<T: Encodable>(_ value: T, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    func testSharedQueriesMixedOriginsAndMissingQuestionAreDeterministic() throws {
        let (plan, collection) = try context(), value = try report(plan, collection)
        XCTAssertEqual(value, try report(plan, collection))
        XCTAssertEqual(value.questions.map(\.id), ["question1", "question2", "question3"])
        XCTAssertEqual(value.questions[0].sourceIDs, ["source1"])
        XCTAssertEqual(value.questions[0].pageEvidenceIDs, ["evidence1"])
        XCTAssertEqual(value.questions[0].availability, .pageEntries); XCTAssertTrue(value.questions[0].gaps.isEmpty)
        XCTAssertEqual(value.questions[1].sourceIDs, ["source1", "source2"])
        XCTAssertEqual(value.questions[1].snippetEvidenceIDs, ["evidence2"])
        XCTAssertEqual(value.questions[1].availability, .mixedEntries)
        XCTAssertEqual(value.questions[2].availability, .noAssociatedSources)
        XCTAssertEqual(value.questions[2].gaps, [.noAssociatedSources, .noRetainedEntries])
        XCTAssertEqual(value.sources.count, 2) // Same final URL never collapses requested aliases.
    }

    func testSnippetOnlyAndMetadataOnlyRemainExplicitGaps() throws {
        let (plan, collection) = try context(text: "", snippet: "Snippet")
        let value = try report(plan, collection)
        XCTAssertEqual(value.questions[0].availability, .snippetEntries) // Nonempty fallback snippet.
        XCTAssertEqual(value.questions[0].gaps, [.snippetOnly])
        let emptySources = collection.sources.map { row in ResearchCollectedSource(id: row.id,
            requestedURLKey: row.requestedURLKey, queryIDs: row.queryIDs, provider: row.provider,
            source: .init(id: row.source.id, title: row.source.title, url: row.source.url, snippet: " \n", pageText: ""), pageFetched: false) }
        let empty = try report(plan, .init(runID: collection.runID, conversationID: collection.conversationID, sources: emptySources))
        XCTAssertEqual(empty.questions[0].availability, .sourcesWithoutEntries)
        XCTAssertEqual(empty.questions[0].gaps, [.noRetainedEntries])
        XCTAssertTrue(empty.evidence.isEmpty)
    }

    func testTruncationIndependentOfAvailableOrAbsentEntries() throws {
        let (plan, collection) = try context(text: "abcdef")
        let value = try report(plan, collection, evidenceLimits: .init(entries: 1, segmentCharacters: 2))
        XCTAssertEqual(value.questions[0].availability, .pageEntries)
        XCTAssertEqual(value.questions[0].gaps, [.ledgerTruncated])
        XCTAssertEqual(value.questions[1].availability, .pageEntries)
        XCTAssertEqual(value.questions[1].gaps, [.ledgerTruncated])
        let oversized = "e" + String(repeating: "\u{301}", count: 40)
        let (otherPlan, otherCollection) = try context(text: oversized, snippet: "")
        let absent = try report(otherPlan, otherCollection, evidenceLimits: .init(segmentBytes: 1))
        XCTAssertEqual(absent.questions[0].availability, .sourcesWithoutEntries)
        XCTAssertEqual(absent.questions[0].gaps, [.noRetainedEntries, .ledgerTruncated])
    }

    func testEmptyCollectionKeepsEveryQuestionAndNoFactualLabel() throws {
        let (plan, collection) = try context()
        let value = try report(plan, .init(runID: collection.runID, conversationID: collection.conversationID, sources: []))
        XCTAssertEqual(value.questions.count, 3); XCTAssertTrue(value.sources.isEmpty); XCTAssertTrue(value.evidence.isEmpty)
        XCTAssertTrue(value.questions.allSatisfy { $0.gaps == [.noAssociatedSources, .noRetainedEntries] })
    }

    func testHostCountAndByteBoundsRejectInsteadOfDroppingRows() throws {
        let (plan, collection) = try context()
        for limits in [try ResearchCoverageLimits(questions: 2), try .init(sourceReferences: 2), try .init(evidenceReferences: 2), try .init(encodedBytes: 10)] {
            XCTAssertThrowsError(try report(plan, collection, limits: limits))
        }
        let value = try report(plan, collection)
        let exact = try JSONEncoder().encode(value).count
        XCTAssertNoThrow(try report(plan, collection, limits: .init(sourceReferences: 3, evidenceReferences: 3)))
        XCTAssertThrowsError(try ResearchCoverageLimits(questions: 33))
        XCTAssertThrowsError(try ResearchCoverageLimits(sourceReferences: 2_049))
        XCTAssertThrowsError(try ResearchCoverageLimits(evidenceReferences: 16_385))
        // Changing the embedded byte limit also changes its serialized digit count.
        XCTAssertThrowsError(try report(plan, collection, limits: .init(encodedBytes: exact - 64)))
    }

    func testGenericDecoderRejectsCorruptGraphsLabelsVersionAndLimits() throws {
        let (plan, collection) = try context(), value = try report(plan, collection)
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["version"] = 2 }, { $0["ledgerContextDigest"] = "bad" },
            { var rows = $0["sources"] as! [[String: Any]]; rows[0]["id"] = "source2"; $0["sources"] = rows },
            { var rows = $0["evidence"] as! [[String: Any]]; rows[0]["sourceID"] = "source3"; $0["evidence"] = rows },
            { var rows = $0["evidence"] as! [[String: Any]]; rows.append(rows[0]); $0["evidence"] = rows },
            { var rows = $0["questions"] as! [[String: Any]]; rows[0]["sourceIDs"] = ["source1", "source1"]; $0["questions"] = rows },
            { var rows = $0["questions"] as! [[String: Any]]; rows[0]["sourceIDs"] = Array(repeating: "source1", count: 65); $0["questions"] = rows },
            { var rows = $0["questions"] as! [[String: Any]]; rows[0]["pageEvidenceIDs"] = Array(repeating: "evidence1", count: 513); $0["questions"] = rows },
            { var rows = $0["questions"] as! [[String: Any]]; rows[0]["pageEvidenceIDs"] = ["evidence2"]; $0["questions"] = rows },
            { var rows = $0["questions"] as! [[String: Any]]; rows[0]["gaps"] = ["snippetOnly"]; $0["questions"] = rows },
            { var rows = $0["questions"] as! [[String: Any]]; rows[0]["availability"] = "answered"; $0["questions"] = rows },
            { var limits = $0["limits"] as! [String: Any]; limits["encodedBytes"] = 0; $0["limits"] = limits }
        ]
        for change in changes { XCTAssertThrowsError(try JSONDecoder().decode(ResearchCoverageReport.self, from: edited(value, change))) }
    }

    func testExpectedDecodeBindsHostLimitsRawBytesRunAndFullLedger() throws {
        let (plan, collection) = try context(), evidenceLimits = try ResearchEvidenceLimits(), limits = try ResearchCoverageLimits()
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: evidenceLimits)
        let value = try report(plan, collection), data = try JSONEncoder().encode(value)
        XCTAssertEqual(try ResearchCoverageReport.decode(data, plan: plan, collection: collection, ledger: ledger, evidenceLimits: evidenceLimits, limits: limits), value)
        XCTAssertThrowsError(try ResearchCoverageReport.decode(data, plan: plan, collection: collection, ledger: ledger, evidenceLimits: evidenceLimits, limits: .init(questions: 31)))
        XCTAssertThrowsError(try ResearchCoverageReport.decode(data, plan: plan, collection: collection, ledger: ledger, evidenceLimits: evidenceLimits, limits: .init(encodedBytes: data.count - 1)))
        let changedSource = collection.sources[0]
        let changed = ResearchCollectedSource(id: changedSource.id, requestedURLKey: changedSource.requestedURLKey,
            queryIDs: changedSource.queryIDs, provider: changedSource.provider,
            source: .init(id: changedSource.source.id, title: changedSource.source.title, url: changedSource.source.url,
                snippet: changedSource.source.snippet, pageText: "Same graph, different text"), pageFetched: true)
        let otherCollection = ResearchCollectionSnapshot(runID: collection.runID, conversationID: collection.conversationID, sources: [changed, collection.sources[1]])
        let otherLedger = try ResearchEvidenceLedger.build(plan: plan, collection: otherCollection, limits: evidenceLimits)
        XCTAssertThrowsError(try ResearchCoverageReport.decode(data, plan: plan, collection: otherCollection, ledger: otherLedger, evidenceLimits: evidenceLimits, limits: limits))
        // An unselected snippet still changes collection context although projected entries match.
        let unusedChanged = ResearchCollectedSource(id: changedSource.id, requestedURLKey: changedSource.requestedURLKey,
            queryIDs: changedSource.queryIDs, provider: changedSource.provider,
            source: .init(id: changedSource.source.id, title: changedSource.source.title, url: changedSource.source.url,
                snippet: "changed unused snippet", pageText: changedSource.source.pageText), pageFetched: true)
        let unusedCollection = ResearchCollectionSnapshot(runID: collection.runID, conversationID: collection.conversationID,
            sources: [unusedChanged, collection.sources[1]])
        let unusedLedger = try ResearchEvidenceLedger.build(plan: plan, collection: unusedCollection, limits: evidenceLimits)
        XCTAssertEqual(unusedLedger.entries, ledger.entries)
        XCTAssertThrowsError(try ResearchCoverageReport.decode(data, plan: plan, collection: unusedCollection, ledger: unusedLedger, evidenceLimits: evidenceLimits, limits: limits))
        let changedPlanData = try edited(plan) {
            var rows = $0["subquestions"] as! [[String: Any]]; rows[0]["question"] = "Different question"; $0["subquestions"] = rows
        }
        let changedPlan = try JSONDecoder().decode(ResearchPlan.self, from: changedPlanData)
        XCTAssertThrowsError(try ResearchCoverageReport.build(plan: changedPlan, collection: collection, ledger: ledger, evidenceLimits: evidenceLimits, limits: limits))
        let changedConversation = ResearchCollectionSnapshot(runID: collection.runID, conversationID: UUID(), sources: collection.sources)
        XCTAssertThrowsError(try ResearchCoverageReport.build(plan: plan, collection: changedConversation, ledger: ledger, evidenceLimits: evidenceLimits, limits: limits))
        let tampered = try edited(value) { $0["runID"] = UUID().uuidString }
        _ = try JSONDecoder().decode(ResearchCoverageReport.self, from: tampered)
        XCTAssertThrowsError(try ResearchCoverageReport.decode(tampered, plan: plan, collection: collection, ledger: ledger, evidenceLimits: evidenceLimits, limits: limits))
    }

    func testBuildRejectsStructurallyValidForgedLedgerBeforeUse() throws {
        let (plan, collection) = try context(), evidenceLimits = try ResearchEvidenceLimits()
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: evidenceLimits)
        let data = try edited(ledger) { var rows = $0["sources"] as! [[String: Any]]; rows[0]["ledgerTruncated"] = true; $0["sources"] = rows }
        let forged = try JSONDecoder().decode(ResearchEvidenceLedger.self, from: data)
        XCTAssertThrowsError(try ResearchCoverageReport.build(plan: plan, collection: collection, ledger: forged, evidenceLimits: evidenceLimits, limits: .init()))
        let textData = try edited(ledger) {
            var rows = $0["entries"] as! [[String: Any]]; rows[0]["text"] = "Fake"; $0["entries"] = rows
        }
        let forgedText = try JSONDecoder().decode(ResearchEvidenceLedger.self, from: textData)
        XCTAssertThrowsError(try ResearchCoverageReport.build(plan: plan, collection: collection, ledger: forgedText, evidenceLimits: evidenceLimits, limits: .init()))
        XCTAssertThrowsError(try ResearchCoverageReport.build(plan: plan, collection: collection, ledger: ledger, evidenceLimits: .init(entries: 255), limits: .init()))
    }

    private func makeOwner(characters: Int = 100_000, clock: PlanningTestClock? = nil, buildLedger: Bool = true) async throws -> ResearchPlanningCoordinator {
        let owner = ResearchPlanningCoordinator(run: try makeRun(characters: characters), limits: try .init(),
            planner: FixtureResearchPlanner(fixture: draft()), clock: clock?.injected ?? PlanningTestClock(Self.start).injected)
        let service = LocalResearchService(resolver: CoverageDNS(), pageFetcher: CoverageHTTP {
            .init(data: Data("Page".utf8), url: $0.url!, statusCode: 200, headers: ["Content-Type": "text/plain"])
        }, accountedSearchFetcher: CoverageHTTP {
            .init(data: Data("<rss><channel><item><title>Title</title><link>https://source.example/a</link><description>Snippet</description></item></channel></rss>".utf8), url: $0.url!, statusCode: 200)
        }, searchAPIKey: { nil })
        _ = try await owner.plan(); _ = try await owner.collect(using: service, limits: .init())
        if buildLedger { _ = try await owner.buildEvidenceLedger(limits: .init()) }
        return owner
    }

    func testCoordinatorRequiresExistingLedgerWithoutImplicitCharge() async throws {
        let owner = try await makeOwner(buildLedger: false), before = await owner.snapshot()
        do { _ = try await owner.buildCoverage(limits: .init()); XCTFail("Needs owned ledger") }
        catch { XCTAssertEqual(error as? ResearchPlanningError, .invalidPhase) }
        let after = await owner.snapshot(); XCTAssertEqual(before.run, after.run)
    }

    func testCoordinatorExactMetadataDeltaAndIdempotence() async throws {
        let owner = try await makeOwner(), before = await owner.snapshot()
        let value = try await owner.buildCoverage(limits: .init()), after = await owner.snapshot()
        XCTAssertEqual(after.run.phase, .evaluating)
        XCTAssertEqual(after.run.usage[.evidenceCharacters]! - before.run.usage[.evidenceCharacters]!, value.metadataCharacterCost)
        XCTAssertEqual(value.metadataCharacterCost, 64 + "source1fetchedPageevidence1source1".count
            + "question1source1evidence1pageEntriesquestion2source1evidence1pageEntriesquestion3source1evidence1pageEntries".count)
        for resource in ResearchRun.Resource.allCases where resource != .evidenceCharacters {
            XCTAssertEqual(after.run.usage[resource], before.run.usage[resource])
        }
        let repeated = try await owner.buildCoverage(limits: .init()); XCTAssertEqual(value, repeated)
        let final = await owner.snapshot(); XCTAssertEqual(final.run, after.run)
        XCTAssertEqual(ResearchRun.checkpointVersion, 3)
    }

    func testCoordinatorBudgetFailureAtomicAndTerminal() async throws {
        let probe = try await makeOwner(), initial = await probe.snapshot()
        let required = try await probe.buildCoverage(limits: .init()).metadataCharacterCost
        let owner = try await makeOwner(characters: initial.run.usage[.evidenceCharacters]! + required - 1)
        let before = await owner.snapshot()
        do { _ = try await owner.buildCoverage(limits: .init()); XCTFail("Metadata budget required") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .budgetExceeded(.evidenceCharacters)) }
        let after = await owner.snapshot(); XCTAssertEqual(after.run.usage, before.run.usage)
        XCTAssertEqual(after.run.failure, .budgetExhausted)
        do { _ = try await owner.buildCoverage(limits: .init()); XCTFail("Terminal") } catch {}
        let final = await owner.snapshot(); XCTAssertEqual(final.run, after.run)
    }

    func testCoordinatorInvalidReportBoundsFailWithoutMetadataCharge() async throws {
        let owner = try await makeOwner(), before = await owner.snapshot()
        do { _ = try await owner.buildCoverage(limits: .init(questions: 2)); XCTFail("Whole report required") }
        catch { XCTAssertEqual(error as? ResearchCoverageReport.ValidationError, .invalidStructure) }
        let after = await owner.snapshot()
        XCTAssertEqual(after.run.failure, .invalidResponse); XCTAssertEqual(after.run.usage, before.run.usage)
        do { _ = try await owner.buildCoverage(limits: .init()); XCTFail("Cannot revive") } catch {}
        let final = await owner.snapshot(); XCTAssertEqual(final.run, after.run)
    }

    func testCachedDeadlineCancellationAndLimitMismatch() async throws {
        let clock = PlanningTestClock(Self.start), owner = try await makeOwner(clock: clock)
        _ = try await owner.buildCoverage(limits: .init())
        let before = await owner.snapshot()
        do { _ = try await owner.buildCoverage(limits: .init(questions: 31)); XCTFail("Changed limits") }
        catch { XCTAssertEqual(error as? ResearchCoverageReport.ValidationError, .invalidBinding) }
        let unchanged = await owner.snapshot(); XCTAssertEqual(before.run, unchanged.run)
        clock.advance(to: Self.start.addingTimeInterval(100))
        do { _ = try await owner.buildCoverage(limits: .init()); XCTFail("Original deadline") } catch {}
        let expired = await owner.snapshot(); XCTAssertEqual(expired.run.failure, .budgetExhausted)
        XCTAssertEqual(expired.run.usage, before.run.usage)
        let cancelled = try await makeOwner(); _ = try await cancelled.buildCoverage(limits: .init())
        try await cancelled.cancel(); let terminal = await cancelled.snapshot()
        do { _ = try await cancelled.buildCoverage(limits: .init()); XCTFail("Cancelled") } catch {}
        let final = await cancelled.snapshot(); XCTAssertEqual(final.run, terminal.run)
    }
}
