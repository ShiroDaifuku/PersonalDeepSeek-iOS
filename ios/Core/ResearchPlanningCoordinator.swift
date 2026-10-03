import Foundation

enum ResearchPlanningError: Error, Equatable {
    case operationInProgress, invalidPhase, providerUnavailable, deadlineExceeded
}

/// Inject both time and cancellable sleep together. A real clock uses the original run deadline;
/// tests can advance a manual clock without waiting for wall time.
struct ResearchPlanningClock: Sendable {
    let now: @Sendable () -> Date
    let sleepUntil: @Sendable (Date) async throws -> Void

    static let continuous = Self(now: { Date() }, sleepUntil: { deadline in
        while true {
            try Task.checkCancellation()
            let seconds = deadline.timeIntervalSinceNow
            guard seconds.isFinite else { throw ResearchRun.ValidationError.invalidClock }
            guard seconds > 0 else { return }
            // ResearchRun deliberately accepts any positive finite wall budget. Chunking
            // avoids overflowing Duration's representation for very distant deadlines.
            try await Task.sleep(for: .seconds(min(seconds, 60)))
        }
    })
}

/// Scheduling-only executor: no search/fetch implementation or evidence enters this layer yet.
typealias ResearchQueryDispatch = @Sendable (ResearchPlan.Query) async throws -> Void

actor ResearchPlanningCoordinator {
    struct Snapshot: Equatable, Sendable {
        let run: ResearchRun
        let plan: ResearchPlan?
        let attemptedQueryIDs: Set<String>
    }
    private var run: ResearchRun
    private var acceptedPlan: ResearchPlan?
    private var attempted = Set<String>()
    private let planner: any ResearchPlanning
    private let limits: ResearchPlanningLimits
    private let clock: ResearchPlanningClock
    private var busy = false
    private var activeTask: Task<ResearchPlannerDraft?, Error>?

    init(run: ResearchRun, limits: ResearchPlanningLimits, planner: any ResearchPlanning,
         clock: ResearchPlanningClock = .continuous) {
        self.run = run
        self.limits = limits
        self.planner = planner
        self.clock = clock
    }

    func snapshot() -> Snapshot { Snapshot(run: run, plan: acceptedPlan, attemptedQueryIDs: attempted) }

    func cancel() throws {
        guard !run.phase.isTerminal else { return }
        activeTask?.cancel()
        // A broken clock must never leave cancellation unable to terminalize the run.
        try run.cancel(at: terminalTime())
    }

    func plan() async throws -> ResearchPlan {
        guard !busy else { throw ResearchPlanningError.operationInProgress }
        guard run.phase == .queued else { throw ResearchPlanningError.invalidPhase }
        busy = true
        defer { busy = false; activeTask = nil }
        do {
            try Task.checkCancellation()
            try run.reserve([.rounds: 1], at: clock.now())
            try run.transition(to: .planning, at: clock.now())
            let input = ResearchPlanningInput(runID: run.id, question: run.query, limits: limits)
            let planner = self.planner
            let draft = try await perform { try await planner.draft(for: input) }
            try checkActive()
            guard let draft else { throw ResearchPlan.ValidationError.invalidQuestions }
            let plan = try ResearchPlan(draft: draft, run: run, limits: limits)
            try run.transition(to: .collecting, at: clock.now())
            acceptedPlan = plan
            return plan
        } catch {
            terminalize(error)
            throw error
        }
    }

    func dispatchQueries(using execute: @escaping ResearchQueryDispatch) async throws {
        guard !busy else { throw ResearchPlanningError.operationInProgress }
        // Repeated calls after success are idempotent and never complete the research run.
        if run.phase == .evaluating, acceptedPlan != nil {
            do { try checkActive() }
            catch { terminalize(error); throw error }
            return
        }
        guard run.phase == .collecting, let plan = acceptedPlan else { throw ResearchPlanningError.invalidPhase }
        busy = true
        defer { busy = false; activeTask = nil }
        do {
            for query in plan.queries where !attempted.contains(query.id) {
                try Task.checkCancellation()
                try checkActive()
                try run.reserve([.queries: 1], at: clock.now())
                attempted.insert(query.id)
                _ = try await perform { try await execute(query); return nil }
                try checkActive()
            }
            try run.transition(to: .evaluating, at: clock.now())
        } catch {
            terminalize(error)
            throw error
        }
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !run.phase.isTerminal else { throw CancellationError() }
        if try run.elapsed(at: clock.now()) >= run.budget.wallSeconds {
            throw ResearchRun.ValidationError.wallTimeExceeded
        }
    }

    private func perform(_ operation: @escaping @Sendable () async throws -> ResearchPlannerDraft?) async throws -> ResearchPlannerDraft? {
        try checkActive()
        let deadline = run.createdAt.addingTimeInterval(run.budget.wallSeconds)
        guard deadline.timeIntervalSinceReferenceDate.isFinite else { throw ResearchRun.ValidationError.invalidClock }
        let sleep = clock.sleepUntil
        let task = Task<ResearchPlannerDraft?, Error> {
            try await withThrowingTaskGroup(of: ResearchPlannerDraft?.self) { group in
                group.addTask { try Task.checkCancellation(); return try await operation() }
                group.addTask { try await sleep(deadline); try Task.checkCancellation(); throw ResearchPlanningError.deadlineExceeded }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
        activeTask = task
        // Swift structured tasks wait for children on exit. Dependencies must honor cancellation;
        // this mechanism cancels cooperative work, it cannot forcibly kill an uncooperative API.
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func terminalTime() -> Date {
        let now = clock.now()
        return now.timeIntervalSinceReferenceDate.isFinite && now >= run.updatedAt ? now : run.updatedAt
    }

    private func terminalize(_ error: Error) {
        guard !run.phase.isTerminal else { return }
        if error is CancellationError {
            try? run.cancel(at: terminalTime())
            return
        }
        let reason: ResearchRun.Failure
        switch error {
        case ResearchRun.ValidationError.wallTimeExceeded,
             ResearchRun.ValidationError.budgetExceeded(_), ResearchPlanningError.deadlineExceeded:
            reason = .budgetExhausted
        case is ResearchPlan.ValidationError, is DecodingError:
            reason = .invalidResponse
        case ResearchPlanningError.providerUnavailable:
            reason = .providerUnavailable
        default: reason = .internalError
        }
        try? run.fail(reason, at: terminalTime())
    }
}
