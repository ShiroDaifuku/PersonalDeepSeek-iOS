import Foundation
import XCTest
@testable import PersonalDeepSeek

/// Cancellable continuations make deadlines deterministic without real sleeps/network.
private final class PlanningTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Date
    private var sleepers: [UUID: (Date, CheckedContinuation<Void, Error>)] = [:]
    private var cancelled = Set<UUID>()
    init(_ date: Date) { time = date }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(to date: Date) {
        lock.lock()
        time = date
        let ready = sleepers.filter { $0.value.0 <= date }
        for id in ready.keys { sleepers.removeValue(forKey: id) }
        lock.unlock()
        for entry in ready.values { entry.1.resume() }
    }
    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                register(id: id, deadline: deadline, continuation: continuation)
            }
        }, onCancel: { self.cancel(id) })
    }
    private func register(id: UUID, deadline: Date, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled.remove(id) != nil {
            lock.unlock(); continuation.resume(throwing: CancellationError())
        } else if time >= deadline {
            lock.unlock(); continuation.resume()
        } else {
            sleepers[id] = (deadline, continuation)
            lock.unlock()
        }
    }
    private func cancel(_ id: UUID) {
        lock.lock()
        let continuation = sleepers.removeValue(forKey: id)?.1
        if continuation == nil { cancelled.insert(id) }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
    var injected: ResearchPlanningClock {
        ResearchPlanningClock(now: { self.now() }, sleepUntil: { try await self.sleep(until: $0) })
    }
}

private struct PlanningClosureFixture: ResearchPlanning {
    let action: @Sendable (ResearchPlanningInput) async throws -> ResearchPlannerDraft
    func draft(for input: ResearchPlanningInput) async throws -> ResearchPlannerDraft { try await action(input) }
}

private actor PlanningCalls {
    var inputs: [ResearchPlanningInput] = []
    var reservations: [ResearchPlanningCoordinator.Snapshot] = []
    func record(_ input: ResearchPlanningInput) { inputs.append(input) }
    func record(_ snapshot: ResearchPlanningCoordinator.Snapshot) { reservations.append(snapshot) }
}

final class ResearchPlanningTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private func makeRun(queries: Int = 10, rounds: Int = 3, wall: Double = 100) throws -> ResearchRun {
        try ResearchRun(conversationID: UUID(), query: "  Exact original\nquestion?  ",
            budget: .init(rounds: rounds, queries: queries, sources: 10, fetches: 10,
                          evidenceCharacters: 1_000, synthesisTokens: 1_000, wallSeconds: wall), now: start)
    }
    private func draft(_ queries: [String] = ["first", "second"]) -> ResearchPlannerDraft {
        .init(subquestions: [.init(question: "What happened?", queries: queries)])
    }
    private func coordinator(_ value: ResearchRun, clock: PlanningTestClock,
                             planner: (any ResearchPlanning)? = nil) throws -> ResearchPlanningCoordinator {
        ResearchPlanningCoordinator(run: value, limits: try .init(),
            planner: planner ?? FixtureResearchPlanner(fixture: draft()), clock: clock.injected)
    }

    /// A cancellation regression should fail within two seconds, then release fixture
    /// continuations so awaiting task.value cannot leave the test process hung.
    private func settled<T: Sendable>(_ task: Task<T, Error>, clock: PlanningTestClock) async -> Result<T, Error> {
        let finished = expectation(description: "operation finished within bound")
        let observer = Task {
            let result = await task.result
            finished.fulfill()
            return result
        }
        await fulfillment(of: [finished], timeout: 2)
        clock.advance(to: .distantFuture)
        return await observer.value
    }

    func testGlobalDedupStableIDsAssociationsAndExactInput() async throws {
        let value = try makeRun()
        let calls = PlanningCalls()
        let fixture = ResearchPlannerDraft(subquestions: [
            .init(question: "  First\nquestion ", queries: ["  Alpha\tBeta", "ALPHA  BETA", "cafe\u{301}"]),
            .init(question: "Second question", queries: ["alpha beta", "café", "第三"])
        ])
        let planner = PlanningClosureFixture { input in await calls.record(input); return fixture }
        let subject = try coordinator(value, clock: PlanningTestClock(start), planner: planner)
        let plan = try await subject.plan()
        XCTAssertEqual(plan.subquestions.map(\.id), ["question1", "question2"])
        XCTAssertEqual(plan.subquestions.map(\.queryIDs), [["query1", "query2"], ["query1", "query2", "query3"]])
        XCTAssertEqual(plan.queries.map(\.text), ["Alpha Beta", "café", "第三"])
        XCTAssertEqual(plan.originalQuestion, value.query)
        let inputs = await calls.inputs
        XCTAssertEqual(inputs, [.init(runID: value.id, question: value.query, limits: try .init())])
        let planned = await subject.snapshot()
        XCTAssertEqual(planned.run.phase, .collecting)
        XCTAssertEqual(planned.run.usage[.rounds], 1)
        XCTAssertEqual(planned.run.usage[.queries], 0)
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try ResearchPlan.decode(data, for: value, limits: .init()), plan)
        XCTAssertEqual(try ResearchPlan(draft: fixture, run: value, limits: .init()), plan)
        XCTAssertThrowsError(try ResearchPlan.decode(data, for: makeRun(), limits: .init()))
        let otherConversation = try ResearchRun(id: value.id, conversationID: UUID(), query: value.query,
                                                budget: value.budget, now: start)
        XCTAssertThrowsError(try ResearchPlan.decode(data, for: otherConversation, limits: .init()))
    }

    func testDraftBoundsAndUnicodeControls() throws {
        let value = try makeRun()
        let limits = try ResearchPlanningLimits(subquestions: 2, queries: 2, questionCharacters: 20)
        let bad: [ResearchPlannerDraft] = [
            .init(subquestions: []), .init(subquestions: Array(repeating: .init(question: "q", queries: ["q"]), count: 3)),
            .init(subquestions: [.init(question: "q", queries: [])]), draft(["a", "b", "c"]),
            .init(subquestions: [.init(question: String(repeating: "a", count: 21), queries: ["q"])]),
            draft([""]), draft([" \n "]), draft([String(repeating: "a", count: 501)])
        ]
        for item in bad { XCTAssertThrowsError(try ResearchPlan(draft: item, run: value, limits: limits)) }
        for scalar in ["\u{0}", "\u{7}", "\u{7F}", "\u{85}", "\u{200B}", "\u{202E}", "\u{2066}", "\u{FEFF}"] {
            XCTAssertThrowsError(try ResearchPlan(draft: draft(["a\(scalar)b"]), run: value, limits: limits))
            XCTAssertThrowsError(try ResearchPlan(draft: .init(subquestions: [.init(question: "a\(scalar)b", queries: ["q"])]), run: value, limits: limits))
        }
        let chinese = String(repeating: "研", count: 500)
        XCTAssertGreaterThan(chinese.utf8.count, 500)
        XCTAssertEqual(try ResearchPlan(draft: draft([chinese]), run: value, limits: limits).queries.first?.text.count, 500)
        XCTAssertThrowsError(try ResearchPlan(draft: draft([chinese + "研"]), run: value, limits: limits))
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(try ResearchPlan(draft: draft([String(repeating: family, count: 500)]), run: value,
                                       limits: limits).queries.first?.text.count, 500)
        XCTAssertEqual(try ResearchPlan(draft: draft(["می‌روم"]), run: value, limits: limits).queries.first?.text, "می‌روم")
        XCTAssertThrowsError(try ResearchPlan(draft: draft(["\u{200D}"]), run: value, limits: limits))
        XCTAssertThrowsError(try ResearchPlan(draft: draft(), run: value, limits: .init(draftBytes: 10)))
        XCTAssertThrowsError(try ResearchPlan(draft: draft(), run: value, limits: .init(planBytes: 10)))
        let data = try JSONEncoder().encode(draft())
        XCTAssertThrowsError(try ResearchPlannerDraft.decode(data, limits: .init(draftBytes: data.count - 1)))
        XCTAssertEqual(try ResearchPlannerDraft.decode(data, limits: .init(draftBytes: data.count)), draft())
        for invalid in [0, -1, Int.max] {
            XCTAssertThrowsError(try ResearchPlanningLimits(draftBytes: invalid))
            XCTAssertThrowsError(try ResearchPlanningLimits(planBytes: invalid))
            XCTAssertThrowsError(try ResearchPlanningLimits(subquestions: invalid))
            XCTAssertThrowsError(try ResearchPlanningLimits(queries: invalid))
            XCTAssertThrowsError(try ResearchPlanningLimits(questionCharacters: invalid))
            XCTAssertThrowsError(try ResearchPlanningLimits(queryCharacters: invalid))
        }
        XCTAssertThrowsError(try ResearchPlanningLimits(queryCharacters: 501))
    }

    private func corrupt(_ plan: ResearchPlan, _ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        mutate(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testPlanDecodingRejectsCorruptionAndOversizedData() throws {
        let value = try makeRun()
        let plan = try ResearchPlan(draft: draft(), run: value, limits: .init())
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["version"] = 2 }, { $0.removeValue(forKey: "runID") },
            { $0.removeValue(forKey: "conversationID") }, { $0["originalQuestion"] = " " },
            { $0["limits"] = ["draftBytes": Int.max, "planBytes": 65_536, "subquestions": 8,
                             "queries": 24, "questionCharacters": 1_000, "queryCharacters": 500] },
            { $0["queries"] = [] }, { $0["subquestions"] = [] },
            { $0["queries"] = [["id": "query1", "text": "same"], ["id": "query2", "text": "SAME"]] },
            { $0["queries"] = [["id": "query1", "text": "first"], ["id": "query1", "text": "second"]] },
            { $0["queries"] = [["id": "query1", "text": " first "], ["id": "query2", "text": "second"]] },
            { $0["subquestions"] = [["id": "question1", "question": "q", "queryIDs": []]] },
            { $0["subquestions"] = [["id": "question1", "question": "q", "queryIDs": ["query3"]]] },
            { $0["subquestions"] = [["id": "question1", "question": "q", "queryIDs": ["query1", "query1"]]] },
            { $0["subquestions"] = [["id": "question1", "question": "q", "queryIDs": ["query1"]]] }
        ]
        for mutation in mutations {
            XCTAssertThrowsError(try JSONDecoder().decode(ResearchPlan.self, from: corrupt(plan, mutation)))
        }
        let data = try JSONEncoder().encode(plan)
        let padded = data + Data(repeating: 32, count: plan.limits.planBytes)
        XCTAssertThrowsError(try ResearchPlan.decode(padded, for: value, limits: plan.limits))
        XCTAssertThrowsError(try ResearchPlan.decode(data, for: value, limits: .init(queries: 23)))
    }

    func testReservationsPrecedeDispatchAndRepeatedCallsAreDeduplicated() async throws {
        let value = try makeRun()
        let subject = try coordinator(value, clock: PlanningTestClock(start))
        _ = try await subject.plan()
        let calls = PlanningCalls()
        let executor: ResearchQueryDispatch = { _ in await calls.record(await subject.snapshot()) }
        try await subject.dispatchQueries(using: executor)
        try await subject.dispatchQueries(using: executor)
        let snapshots = await calls.reservations
        XCTAssertEqual(snapshots.map { $0.run.usage[.queries]! }, [1, 2])
        XCTAssertEqual(snapshots.map { $0.attemptedQueryIDs.count }, [1, 2])
        let final = await subject.snapshot()
        XCTAssertEqual(final.run.phase, .evaluating)
        XCTAssertEqual(final.run.createdAt, value.createdAt)
        XCTAssertEqual(final.run.usage[.rounds], 1)
        XCTAssertEqual(final.run.usage[.queries], 2)
    }

    func testBudgetExhaustionNeverInvokesUnreservedWorkOrResetsCheckpoint() async throws {
        var value = try makeRun(queries: 1, wall: 10)
        try value.reserve([.queries: 1], at: start.addingTimeInterval(2))
        value = try JSONDecoder().decode(ResearchRun.self, from: JSONEncoder().encode(value))
        let clock = PlanningTestClock(start.addingTimeInterval(3))
        let subject = try coordinator(value, clock: clock)
        _ = try await subject.plan()
        let calls = PlanningCalls()
        do { try await subject.dispatchQueries { _ in await calls.record(await subject.snapshot()) }; XCTFail("must exhaust") }
        catch { XCTAssertEqual(error as? ResearchRun.ValidationError, .budgetExceeded(.queries)) }
        let snapshots = await calls.reservations
        XCTAssertTrue(snapshots.isEmpty)
        let final = await subject.snapshot()
        XCTAssertEqual(final.run.failure, .budgetExhausted)
        XCTAssertEqual(final.run.usage[.queries], 1)
        XCTAssertEqual(try final.run.elapsed(at: start.addingTimeInterval(9)), 9)
        XCTAssertEqual(final.run.createdAt, start)

        var exhausted = try makeRun(rounds: 1)
        try exhausted.reserve([.rounds: 1], at: start)
        let plannedCalls = PlanningCalls()
        let fixture = draft()
        let planner = PlanningClosureFixture { input in await plannedCalls.record(input); return fixture }
        let another = try coordinator(exhausted, clock: PlanningTestClock(start), planner: planner)
        do { _ = try await another.plan(); XCTFail("must exhaust round") } catch {}
        let inputs = await plannedCalls.inputs
        XCTAssertTrue(inputs.isEmpty)
        let state = await another.snapshot()
        XCTAssertEqual(state.run.failure, .budgetExhausted)
        XCTAssertEqual(state.run.usage[.rounds], 1)
    }

    func testInvalidDraftAndProviderFailureAreClassifiedWithoutRefund() async throws {
        let invalid = try coordinator(makeRun(), clock: PlanningTestClock(start), planner: FixtureResearchPlanner(fixture: draft([" "])))
        do { _ = try await invalid.plan(); XCTFail("invalid draft accepted") } catch {}
        let invalidState = await invalid.snapshot()
        XCTAssertEqual(invalidState.run.failure, .invalidResponse)
        XCTAssertEqual(invalidState.run.usage[.rounds], 1)
        XCTAssertNil(invalidState.plan)
        let subject = try coordinator(makeRun(), clock: PlanningTestClock(start))
        _ = try await subject.plan()
        do { try await subject.dispatchQueries { _ in throw ResearchPlanningError.providerUnavailable }; XCTFail("failure ignored") } catch {}
        let final = await subject.snapshot()
        XCTAssertEqual(final.run.failure, .providerUnavailable)
        XCTAssertEqual(final.run.usage[.queries], 1)
        XCTAssertEqual(final.attemptedQueryIDs, ["query1"])
    }

    func testCancellationBeforeAndDuringPlannerSuppressesLateResult() async throws {
        let untouched = try coordinator(makeRun(), clock: PlanningTestClock(start))
        try await untouched.cancel()
        do { _ = try await untouched.plan(); XCTFail("cancelled plan began") } catch {}
        let before = await untouched.snapshot()
        XCTAssertEqual(before.run.phase, .cancelled)
        XCTAssertEqual(before.run.usage[.rounds], 0)

        let clock = PlanningTestClock(start)
        let entered = expectation(description: "planner entered")
        let fixture = draft()
        // Deliberately catches cancellation and returns a late draft: publication must still be blocked.
        let planner = PlanningClosureFixture { _ in
            entered.fulfill()
            do { try await clock.sleep(until: .distantFuture) } catch {}
            return fixture
        }
        let subject = try coordinator(makeRun(), clock: clock, planner: planner)
        let work = Task { try await subject.plan() }
        await fulfillment(of: [entered], timeout: 2)
        do { _ = try await subject.plan(); XCTFail("overlap allowed") }
        catch { XCTAssertEqual(error as? ResearchPlanningError, .operationInProgress) }
        try await subject.cancel()
        do { _ = try await settled(work, clock: clock).get(); XCTFail("cancel ignored") } catch {}
        let final = await subject.snapshot()
        XCTAssertEqual(final.run.phase, .cancelled)
        XCTAssertNil(final.plan)
        XCTAssertEqual(final.run.usage[.rounds], 1)
    }

    func testQueryCancellationAndOverlapKeepAttemptedBudget() async throws {
        let clock = PlanningTestClock(start)
        let subject = try coordinator(makeRun(), clock: clock)
        _ = try await subject.plan()
        let entered = expectation(description: "query entered")
        let work = Task {
            try await subject.dispatchQueries { _ in
                entered.fulfill()
                do { try await clock.sleep(until: .distantFuture) } catch {}
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        do { try await subject.dispatchQueries { _ in XCTFail("overlapping executor") }; XCTFail("overlap allowed") }
        catch { XCTAssertEqual(error as? ResearchPlanningError, .operationInProgress) }
        try await subject.cancel()
        do { try await settled(work, clock: clock).get(); XCTFail("cancel ignored") } catch {}
        let final = await subject.snapshot()
        XCTAssertEqual(final.run.phase, .cancelled)
        XCTAssertEqual(final.run.usage[.queries], 1)
        XCTAssertEqual(final.attemptedQueryIDs, ["query1"])
    }

    func testDeadlineInterruptsPlannerAndQueryWithOriginalWallBudget() async throws {
        for stage in ["planner", "query"] {
            let clock = PlanningTestClock(start)
            let entered = expectation(description: "\(stage) entered")
            let fixture = draft()
            let planner = PlanningClosureFixture { _ in
                if stage == "planner" { entered.fulfill(); try await clock.sleep(until: .distantFuture) }
                return fixture
            }
            let subject = try coordinator(makeRun(wall: 10), clock: clock, planner: planner)
            if stage == "query" { _ = try await subject.plan(); clock.advance(to: start.addingTimeInterval(8)) }
            let work = Task {
                if stage == "planner" { _ = try await subject.plan() }
                else { try await subject.dispatchQueries { _ in entered.fulfill(); try await clock.sleep(until: .distantFuture) } }
            }
            await fulfillment(of: [entered], timeout: 2)
            clock.advance(to: start.addingTimeInterval(10))
            do { try await settled(work, clock: clock).get(); XCTFail("deadline ignored") } catch {}
            let final = await subject.snapshot()
            XCTAssertEqual(final.run.phase, .failed)
            XCTAssertEqual(final.run.failure, .budgetExhausted)
            XCTAssertEqual(final.run.updatedAt, start.addingTimeInterval(10))
            XCTAssertEqual(final.run.usage[.queries], stage == "query" ? 1 : 0)
        }
    }

    func testBackwardsClockTerminalizesAtLastValidTimestampAndCallerCancellation() async throws {
        let clock = PlanningTestClock(start.addingTimeInterval(3))
        let fixture = draft()
        let initialTime = start
        let planner = PlanningClosureFixture { _ in clock.advance(to: initialTime); return fixture }
        let subject = try coordinator(makeRun(), clock: clock, planner: planner)
        do { _ = try await subject.plan(); XCTFail("backwards clock allowed") } catch {}
        let final = await subject.snapshot()
        XCTAssertEqual(final.run.failure, .internalError)
        XCTAssertEqual(final.run.updatedAt, start.addingTimeInterval(3))
        XCTAssertNil(final.plan)

        let otherClock = PlanningTestClock(start)
        let entered = expectation(description: "planner for parent cancellation")
        let otherPlanner = PlanningClosureFixture { _ in
            entered.fulfill(); try await otherClock.sleep(until: .distantFuture); return fixture
        }
        let another = try coordinator(makeRun(), clock: otherClock, planner: otherPlanner)
        let work = Task { try await another.plan() }
        await fulfillment(of: [entered], timeout: 2)
        work.cancel()
        do { _ = try await settled(work, clock: otherClock).get(); XCTFail("caller cancellation ignored") } catch {}
        let cancelled = await another.snapshot()
        XCTAssertEqual(cancelled.run.phase, .cancelled)
        XCTAssertEqual(cancelled.run.usage[.rounds], 1)
    }

    func testNonQueuedCheckpointIsRejectedWithoutResettingCounters() async throws {
        var value = try makeRun()
        try value.reserve([.rounds: 1], at: start)
        try value.transition(to: .planning, at: start)
        let subject = try coordinator(value, clock: PlanningTestClock(start))
        do { _ = try await subject.plan(); XCTFail("unsupported resume accepted") }
        catch { XCTAssertEqual(error as? ResearchPlanningError, .invalidPhase) }
        let final = await subject.snapshot()
        XCTAssertEqual(final.run, value)
    }

    func testIdempotentDispatchStillTerminalizesDeadlineAndCallerCancellation() async throws {
        let clock = PlanningTestClock(start)
        let subject = try coordinator(makeRun(wall: 10), clock: clock)
        _ = try await subject.plan()
        try await subject.dispatchQueries { _ in }
        clock.advance(to: start.addingTimeInterval(10))
        do { try await subject.dispatchQueries { _ in XCTFail("duplicate dispatch") }; XCTFail("deadline ignored") } catch {}
        let expired = await subject.snapshot()
        XCTAssertEqual(expired.run.failure, .budgetExhausted)
        XCTAssertEqual(expired.run.usage[.queries], 2)

        let cancellationClock = PlanningTestClock(start)
        let another = try coordinator(makeRun(), clock: cancellationClock)
        _ = try await another.plan()
        try await another.dispatchQueries { _ in }
        let entered = expectation(description: "caller task gated")
        let work = Task {
            entered.fulfill()
            do { try await cancellationClock.sleep(until: .distantFuture) } catch {}
            try await another.dispatchQueries { _ in XCTFail("duplicate dispatch") }
        }
        await fulfillment(of: [entered], timeout: 2)
        work.cancel()
        do { try await settled(work, clock: cancellationClock).get(); XCTFail("cancellation ignored") } catch {}
        let cancelled = await another.snapshot()
        XCTAssertEqual(cancelled.run.phase, .cancelled)
        XCTAssertEqual(cancelled.run.usage[.queries], 2)
    }

    func testAlreadyCancelledCallerAndBeforeQueryCancellationDoNotReserve() async throws {
        let clock = PlanningTestClock(start)
        let subject = try coordinator(makeRun(), clock: clock)
        let entered = expectation(description: "already cancelled caller")
        let work = Task {
            entered.fulfill()
            do { try await clock.sleep(until: .distantFuture) } catch {}
            _ = try await subject.plan()
        }
        await fulfillment(of: [entered], timeout: 2)
        work.cancel()
        do { try await settled(work, clock: clock).get(); XCTFail("cancelled caller entered planner") } catch {}
        let cancelled = await subject.snapshot()
        XCTAssertEqual(cancelled.run.phase, .cancelled)
        XCTAssertEqual(cancelled.run.usage[.rounds], 0)

        let another = try coordinator(makeRun(), clock: PlanningTestClock(start))
        _ = try await another.plan()
        try await another.cancel()
        do { try await another.dispatchQueries { _ in XCTFail("cancelled executor") }; XCTFail("cancelled query began") } catch {}
        let beforeQuery = await another.snapshot()
        XCTAssertEqual(beforeQuery.run.phase, .cancelled)
        XCTAssertEqual(beforeQuery.run.usage[.queries], 0)
    }

    func testHugeWallBudgetCannotOverflowDeadlineOrDuration() async throws {
        let sleep = Task { try await ResearchPlanningClock.continuous.sleepUntil(Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude)) }
        sleep.cancel()
        do { try await sleep.value; XCTFail("sleep cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }

        let hugeStart = Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude)
        let value = try ResearchRun(conversationID: UUID(), query: "question",
            budget: .init(rounds: 1, queries: 1, sources: 1, fetches: 1, evidenceCharacters: 1,
                          synthesisTokens: 1, wallSeconds: Double.greatestFiniteMagnitude), now: hugeStart)
        let calls = PlanningCalls()
        let fixture = draft()
        let planner = PlanningClosureFixture { input in await calls.record(input); return fixture }
        let subject = try coordinator(value, clock: PlanningTestClock(hugeStart), planner: planner)
        do { _ = try await subject.plan(); XCTFail("nonfinite deadline accepted") } catch {}
        let inputs = await calls.inputs
        XCTAssertTrue(inputs.isEmpty)
        let final = await subject.snapshot()
        XCTAssertEqual(final.run.failure, .internalError)
        XCTAssertEqual(final.run.usage[.rounds], 1)
        XCTAssertEqual(final.run.updatedAt, hugeStart)
    }
}
