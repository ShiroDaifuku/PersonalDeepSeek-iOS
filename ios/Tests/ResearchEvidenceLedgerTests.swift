import Foundation
import XCTest
@testable import PersonalDeepSeek

private struct LedgerHTTP: ResearchHTTPFetching {
    let action: @Sendable (URLRequest) async throws -> ResearchHTTPResponse
    func data(for request: URLRequest) async throws -> ResearchHTTPResponse { try await action(request) }
}
private struct LedgerDNS: ResearchDNSResolving {
    func addresses(for host: String) async throws -> [String] { ["8.8.8.8"] }
}

final class ResearchEvidenceLedgerTests: XCTestCase {
    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private func makeRun(characters: Int = 10_000) throws -> ResearchRun {
        try ResearchRun(conversationID: UUID(), query: "question", budget: .init(rounds: 2, queries: 10,
            sources: 10, fetches: 10, evidenceCharacters: characters, synthesisTokens: 100, wallSeconds: 100), now: Self.start)
    }
    private func draft() -> ResearchPlannerDraft {
        .init(subquestions: [.init(question: "first", queries: ["one"]),
                            .init(question: "second", queries: ["one", "two"])])
    }
    private func context(page: String = "Page body", snippet: String = "Snippet", fetched: Bool = true,
                         queries: [String] = ["query1", "query2"]) throws -> (ResearchPlan, ResearchCollectionSnapshot) {
        let run = try makeRun(), plan = try ResearchPlan(draft: draft(), run: run, limits: .init())
        let source = ResearchCollectedSource(id: "source1", requestedURLKey: "https://source.example/a",
            queryIDs: queries, provider: .bingRSS,
            source: .init(title: "Title", url: URL(string: "https://source.example/final")!, snippet: snippet, pageText: page),
            pageFetched: fetched)
        return (plan, .init(runID: run.id, conversationID: run.conversationID, sources: [source]))
    }
    private func replacing(_ collection: ResearchCollectionSnapshot, sources: [ResearchCollectedSource]) -> ResearchCollectionSnapshot {
        .init(runID: collection.runID, conversationID: collection.conversationID, sources: sources)
    }
    private func edited(_ ledger: ResearchEvidenceLedger, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    func testStableIDsAssociationsAndFirstObservationProvenance() throws {
        let (plan, collection) = try context()
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: .init())
        XCTAssertEqual(ledger, try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: .init()))
        XCTAssertEqual(ledger.sources[0].questionIDs, ["question1", "question2"])
        XCTAssertEqual(ledger.sources[0].queryIDs, ["query1", "query2"])
        XCTAssertEqual(ledger.sources[0].firstObservationQueryID, "query1")
        XCTAssertEqual(ledger.sources[0].firstObservationProvider, .bingRSS)
        XCTAssertEqual(ledger.sources[0].origin, .fetchedPage)
        XCTAssertEqual(ledger.entries.map(\.id), ["evidence1"])
        XCTAssertEqual(ledger.entries[0].text, "Page body")
        XCTAssertFalse(ledger.sources[0].ledgerTruncated)
        XCTAssertEqual(ledger.sources[0].collectedCharacters, 9)
    }

    func testEmptyOrWhitespacePageUsesSnippetAndEmptyCollectionIsValid() throws {
        for page in ["", " \n\t "] {
            let (plan, collection) = try context(page: page)
            let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: .init())
            XCTAssertEqual(ledger.sources[0].origin, .searchSnippet)
            XCTAssertEqual(ledger.entries[0].text, "Snippet")
            let empty = try ResearchEvidenceLedger.build(plan: plan, collection: replacing(collection, sources: []), limits: .init())
            XCTAssertTrue(empty.sources.isEmpty); XCTAssertTrue(empty.entries.isEmpty)
            XCTAssertEqual(empty.metadataCharacterCost, 128)
        }
        let (plan, collection) = try context(page: "", snippet: " \n ", fetched: false)
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: .init())
        XCTAssertTrue(ledger.entries.isEmpty); XCTAssertFalse(ledger.sources[0].ledgerTruncated)
    }

    func testRequestedAliasesRemainSeparateEvenWithSameFinalURL() throws {
        let (plan, collection) = try context(), first = collection.sources[0]
        let second = ResearchCollectedSource(id: "source2", requestedURLKey: "https://source.example/b",
            queryIDs: ["query2"], provider: .brave, source: first.source, pageFetched: true)
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: replacing(collection, sources: [first, second]), limits: .init())
        XCTAssertEqual(ledger.sources.map(\.id), ["source1", "source2"])
        XCTAssertEqual(ledger.sources[0].finalURL, ledger.sources[1].finalURL)
        XCTAssertEqual(ledger.sources[1].questionIDs, ["question2"])
        XCTAssertEqual(ledger.entries.map(\.sourceID), ["source1", "source2"])
        let both = replacing(collection, sources: [first, second])
        XCTAssertThrowsError(try ResearchEvidenceLedger.build(plan: plan, collection: both, limits: .init(sources: 1)))
        let textBound = try ResearchEvidenceLedger.build(plan: plan, collection: both, limits: .init(textCharacters: 9))
        XCTAssertEqual(textBound.entries.map(\.sourceID), ["source1"])
        XCTAssertFalse(textBound.sources[0].ledgerTruncated); XCTAssertTrue(textBound.sources[1].ledgerTruncated)
        let entryBound = try ResearchEvidenceLedger.build(plan: plan, collection: both, limits: .init(entries: 1))
        XCTAssertEqual(entryBound.entries.map(\.sourceID), ["source1"])
        XCTAssertTrue(entryBound.sources[1].ledgerTruncated)
    }

    func testCharacterAndByteSegmentationPreservesUnicodeOffsets() throws {
        let (plan, collection) = try context(page: " 你好🙂ab ")
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection,
            limits: .init(segmentCharacters: 3, segmentBytes: 6))
        XCTAssertEqual(ledger.entries.map(\.text), ["你", "好", "🙂ab"])
        XCTAssertEqual(ledger.entries.map(\.characterOffset), [1, 2, 3])
        XCTAssertTrue(ledger.entries.allSatisfy { $0.text.count <= 3 && $0.text.utf8.count <= 6 })
        XCTAssertFalse(ledger.sources[0].ledgerTruncated)
    }

    func testEntryAndGlobalTextCeilingsMarkAdditionalTruncation() throws {
        let (plan, collection) = try context(page: "abcdef")
        let entryBound = try ResearchEvidenceLedger.build(plan: plan, collection: collection,
            limits: .init(entries: 1, segmentCharacters: 2))
        XCTAssertEqual(entryBound.entries.map(\.text), ["ab"])
        XCTAssertTrue(entryBound.sources[0].ledgerTruncated)
        let textBound = try ResearchEvidenceLedger.build(plan: plan, collection: collection,
            limits: .init(segmentCharacters: 2, textCharacters: 3))
        XCTAssertEqual(textBound.entries.map(\.text), ["ab", "c"])
        XCTAssertTrue(textBound.sources[0].ledgerTruncated)
        XCTAssertEqual(textBound.sources[0].collectedCharacters, 6)
    }

    func testOversizedGraphemeStopsPrefixExplicitlyWithoutSplitting() throws {
        let (plan, collection) = try context(page: "a" + "e" + String(repeating: "\u{301}", count: 40) + "z")
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection,
            limits: .init(segmentBytes: 4))
        XCTAssertEqual(ledger.entries.map(\.text), ["a"])
        XCTAssertTrue(ledger.sources[0].ledgerTruncated)
        XCTAssertEqual(ledger.sources[0].collectedCharacters, 3)
    }

    func testRejectsInvalidCollectionReferencesDuplicateKeysAndInconsistentFetch() throws {
        let (plan, collection) = try context()
        for queries in [[], ["query1", "query1"], ["query3"]] {
            let (_, invalid) = try context(queries: queries)
            XCTAssertThrowsError(try ResearchEvidenceLedger.build(plan: plan,
                collection: replacing(collection, sources: invalid.sources), limits: .init()))
        }
        let (_, notFetched) = try context(fetched: false)
        XCTAssertThrowsError(try ResearchEvidenceLedger.build(plan: plan,
            collection: replacing(collection, sources: notFetched.sources), limits: .init()))
        let first = collection.sources[0]
        let duplicate = ResearchCollectedSource(id: "source2", requestedURLKey: first.requestedURLKey,
            queryIDs: ["query1"], provider: .brave, source: first.source, pageFetched: true)
        XCTAssertThrowsError(try ResearchEvidenceLedger.build(plan: plan,
            collection: replacing(collection, sources: [first, duplicate]), limits: .init()))
    }

    func testDecodeRequiresExactExpectedContextAndHostLimits() throws {
        let (plan, collection) = try context(), limits = try ResearchEvidenceLimits()
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: limits)
        let data = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try ResearchEvidenceLedger.decode(data, plan: plan, collection: collection, limits: limits), ledger)
        let (otherPlan, _) = try context()
        XCTAssertThrowsError(try ResearchEvidenceLedger.decode(data, plan: otherPlan, collection: collection, limits: limits))
        let (_, modified) = try context(page: "Changed page")
        XCTAssertThrowsError(try ResearchEvidenceLedger.decode(data, plan: plan,
            collection: replacing(collection, sources: modified.sources), limits: limits))
        XCTAssertThrowsError(try ResearchEvidenceLedger.decode(data, plan: plan, collection: collection, limits: .init(entries: 255)))
        XCTAssertThrowsError(try ResearchEvidenceLedger.decode(data, plan: plan, collection: collection, limits: .init(encodedBytes: data.count - 1)))
        let changedConversation = ResearchCollectionSnapshot(runID: collection.runID, conversationID: UUID(), sources: collection.sources)
        XCTAssertThrowsError(try ResearchEvidenceLedger.decode(data, plan: plan, collection: changedConversation, limits: limits))
        // Matching UUIDs and graph edges cannot conceal different accepted plan text.
        var planObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var questions = planObject["subquestions"] as! [[String: Any]]
        questions[0]["question"] = "different accepted question"; planObject["subquestions"] = questions
        let changedPlan = try JSONDecoder().decode(ResearchPlan.self, from: JSONSerialization.data(withJSONObject: planObject))
        XCTAssertEqual(changedPlan.runID, plan.runID)
        XCTAssertThrowsError(try ResearchEvidenceLedger.decode(data, plan: changedPlan, collection: collection, limits: limits))
        // Unselected snippet and underlying source UUID are also part of the collection context.
        let original = collection.sources[0]
        for source in [
            ResearchSource(id: original.source.id, title: original.source.title, url: original.source.url,
                           snippet: "changed unused snippet", pageText: original.source.pageText),
            ResearchSource(id: UUID(), title: original.source.title, url: original.source.url,
                           snippet: original.source.snippet, pageText: original.source.pageText)
        ] {
            let changed = ResearchCollectedSource(id: original.id, requestedURLKey: original.requestedURLKey,
                queryIDs: original.queryIDs, provider: original.provider, source: source, pageFetched: original.pageFetched)
            XCTAssertThrowsError(try ResearchEvidenceLedger.decode(data, plan: plan,
                collection: replacing(collection, sources: [changed]), limits: limits))
        }
    }

    func testGenericDecoderRejectsFutureSchemaDanglingDuplicateAndEmptyEntries() throws {
        let (plan, collection) = try context()
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: .init())
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["version"] = 2 },
            { $0["planContextDigest"] = String(repeating: "G", count: 64) },
            { $0["collectionContextDigest"] = "" },
            { var entries = $0["entries"] as! [[String: Any]]; entries[0]["sourceID"] = "source2"; $0["entries"] = entries },
            { var entries = $0["entries"] as! [[String: Any]]; entries.append(entries[0]); $0["entries"] = entries },
            { var entries = $0["entries"] as! [[String: Any]]; entries[0]["text"] = " \n"; $0["entries"] = entries },
            { var entries = $0["entries"] as! [[String: Any]]; entries[0]["characterOffset"] = -1; $0["entries"] = entries },
            { var sources = $0["sources"] as! [[String: Any]]; sources[0]["queryIDs"] = ["query1", "query1"]; $0["sources"] = sources },
            { var limits = $0["limits"] as! [String: Any]; limits["entries"] = 513; $0["limits"] = limits }
        ]
        for change in changes { XCTAssertThrowsError(try JSONDecoder().decode(ResearchEvidenceLedger.self, from: edited(ledger, change))) }
    }

    func testStructurallyValidTamperingStillFailsExpectedProjection() throws {
        let (plan, collection) = try context(), limits = try ResearchEvidenceLimits()
        let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: limits)
        let data = try edited(ledger) {
            var sources = $0["sources"] as! [[String: Any]]
            sources[0]["firstObservationProvider"] = "brave"; sources[0]["ledgerTruncated"] = true
            $0["sources"] = sources
        }
        _ = try JSONDecoder().decode(ResearchEvidenceLedger.self, from: data)
        XCTAssertThrowsError(try ResearchEvidenceLedger.decode(data, plan: plan, collection: collection, limits: limits))
        let associationData = try edited(ledger) {
            var sources = $0["sources"] as! [[String: Any]]
            sources[0]["queryIDs"] = ["query1"]; sources[0]["questionIDs"] = ["question1"]
            $0["sources"] = sources
        }
        _ = try JSONDecoder().decode(ResearchEvidenceLedger.self, from: associationData)
        XCTAssertThrowsError(try ResearchEvidenceLedger.decode(associationData, plan: plan, collection: collection, limits: limits))
    }

    func testSourceEncodedAndCollectionTextBoundsCannotBeBypassed() throws {
        let (plan, collection) = try context(page: String(repeating: "x", count: 24_001))
        XCTAssertThrowsError(try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: .init()))
        let (validPlan, validCollection) = try context()
        XCTAssertThrowsError(try ResearchEvidenceLedger.build(plan: validPlan, collection: validCollection, limits: .init(encodedBytes: 10)))
        XCTAssertThrowsError(try ResearchEvidenceLimits(segmentBytes: 0))
    }

    private func makeOwner(characters: Int = 10_000, clock: PlanningTestClock? = nil,
                       noResults: Bool = false) async throws -> ResearchPlanningCoordinator {
        let owner = ResearchPlanningCoordinator(run: try makeRun(characters: characters), limits: try .init(),
            planner: FixtureResearchPlanner(fixture: draft()), clock: clock?.injected ?? PlanningTestClock(Self.start).injected)
        let service = LocalResearchService(resolver: LedgerDNS(),
            pageFetcher: LedgerHTTP { .init(data: Data("Page".utf8), url: $0.url!, statusCode: 200,
                headers: ["Content-Type": "text/plain"]) },
            accountedSearchFetcher: LedgerHTTP {
                let rss = noResults ? "<rss><channel></channel></rss>" : "<rss><channel><item><title>Title</title><link>https://source.example/a</link><description>Snippet</description></item></channel></rss>"
                return .init(data: Data(rss.utf8), url: $0.url!, statusCode: 200)
            }, searchAPIKey: { nil })
        _ = try await owner.plan()
        _ = try await owner.collect(using: service, limits: .init())
        return owner
    }

    func testCoordinatorChargesOnlyNovelMetadataOnceAndKeepsEvaluating() async throws {
        let owner = try await makeOwner(), before = await owner.snapshot()
        let collection = await owner.collectionSnapshot()
        let ledger = try await owner.buildEvidenceLedger(limits: .init())
        let after = await owner.snapshot()
        XCTAssertEqual(after.run.phase, .evaluating)
        XCTAssertEqual(after.run.usage[.evidenceCharacters]! - before.run.usage[.evidenceCharacters]!, ledger.metadataCharacterCost)
        XCTAssertEqual(ledger.metadataCharacterCost,
            128 + "question1question2query1fetchedPageevidence1source1".count)
        XCTAssertEqual(before.run.usage[.evidenceCharacters], collection.sources.reduce(0) { $0 + $1.characterCost })
        for resource in ResearchRun.Resource.allCases where resource != .evidenceCharacters {
            XCTAssertEqual(before.run.usage[resource], after.run.usage[resource])
        }
        let repeatedLedger = try await owner.buildEvidenceLedger(limits: .init())
        XCTAssertEqual(repeatedLedger, ledger)
        let repeated = await owner.snapshot()
        XCTAssertEqual(repeated.run, after.run)
        XCTAssertEqual(ResearchRun.checkpointVersion, 3)
    }

    func testCoordinatorBudgetFailureIsAtomicAndTerminal() async throws {
        let probe = try await makeOwner(), initial = await probe.snapshot()
        let required = try await probe.buildEvidenceLedger(limits: .init()).metadataCharacterCost
        let owner = try await makeOwner(characters: initial.run.usage[.evidenceCharacters]! + required - 1)
        let before = await owner.snapshot()
        do { _ = try await owner.buildEvidenceLedger(limits: .init()); XCTFail("Must reserve metadata") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .budgetExceeded(.evidenceCharacters)) }
        let after = await owner.snapshot()
        XCTAssertEqual(after.run.usage, before.run.usage); XCTAssertEqual(after.run.failure, .budgetExhausted)
        do { _ = try await owner.buildEvidenceLedger(limits: .init()); XCTFail("Terminal run cannot build") } catch {}
        let final = await owner.snapshot(); XCTAssertEqual(final.run, after.run)
    }

    func testCachedLedgerRechecksOriginalDeadlineAndCancellation() async throws {
        let clock = PlanningTestClock(Self.start), owner = try await makeOwner(clock: clock)
        _ = try await owner.buildEvidenceLedger(limits: .init())
        let before = await owner.snapshot()
        clock.advance(to: Self.start.addingTimeInterval(100))
        do { _ = try await owner.buildEvidenceLedger(limits: .init()); XCTFail("Cached result must check deadline") } catch {}
        let after = await owner.snapshot()
        XCTAssertEqual(after.run.failure, .budgetExhausted); XCTAssertEqual(before.run.usage, after.run.usage)
        let cancelled = try await makeOwner()
        _ = try await cancelled.buildEvidenceLedger(limits: .init())
        try await cancelled.cancel()
        let terminal = await cancelled.snapshot()
        do { _ = try await cancelled.buildEvidenceLedger(limits: .init()); XCTFail("Cancelled run cannot return evidence") } catch {}
        let final = await cancelled.snapshot(); XCTAssertEqual(final.run, terminal.run)
    }

    func testEmptyCollectionLedgerChargesOnlyContextAndDispatchOnlyCannotBuild() async throws {
        let owner = try await makeOwner(noResults: true), before = await owner.snapshot()
        let ledger = try await owner.buildEvidenceLedger(limits: .init())
        XCTAssertTrue(ledger.entries.isEmpty); XCTAssertEqual(ledger.metadataCharacterCost, 128)
        let after = await owner.snapshot()
        XCTAssertEqual(after.run.usage[.evidenceCharacters]! - before.run.usage[.evidenceCharacters]!, 128)
        XCTAssertEqual(after.run.phase, before.run.phase)
        let dispatchOnly = ResearchPlanningCoordinator(run: try makeRun(), limits: try .init(),
            planner: FixtureResearchPlanner(fixture: draft()), clock: PlanningTestClock(Self.start).injected)
        _ = try await dispatchOnly.plan(); try await dispatchOnly.dispatchQueries { _ in }
        do { _ = try await dispatchOnly.buildEvidenceLedger(limits: .init()); XCTFail("No charged collection") } catch {}
    }

    func testCachedLimitMismatchRejectsWithoutMutation() async throws {
        let owner = try await makeOwner()
        _ = try await owner.buildEvidenceLedger(limits: .init())
        let before = await owner.snapshot()
        do { _ = try await owner.buildEvidenceLedger(limits: .init(entries: 255)); XCTFail("Cannot replace cached bounds") }
        catch { XCTAssertEqual(error as? ResearchEvidenceLedger.ValidationError, .invalidBinding) }
        let after = await owner.snapshot(); XCTAssertEqual(after.run, before.run)
    }
}
