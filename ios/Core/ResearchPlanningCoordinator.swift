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
    private var activeCancellation: (() -> Void)?
    private var operationToken: UUID?
    private var collected: [ResearchCollectedSource] = []
    private var collectionFinished = false
    private var evidenceLedger: ResearchEvidenceLedger?
    private var coverageReport: ResearchCoverageReport?
    private var refinementProposal: ResearchRefinementProposal?

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
        activeCancellation?()
        operationToken = nil
        // A broken clock must never leave cancellation unable to terminalize the run.
        try run.cancel(at: terminalTime())
    }

    func plan() async throws -> ResearchPlan {
        guard !busy else { throw ResearchPlanningError.operationInProgress }
        guard run.phase == .queued else { throw ResearchPlanningError.invalidPhase }
        busy = true
        defer { busy = false; activeCancellation = nil }
        do {
            try Task.checkCancellation()
            var costs = planner.reservationCosts
            guard costs[.rounds] == nil else { throw ResearchRun.ValidationError.invalidReservation }
            costs[.rounds] = 1
            try run.reserve(costs, at: clock.now())
            try run.transition(to: .planning, at: clock.now())
            let input = ResearchPlanningInput(runID: run.id, question: run.query, limits: limits)
            let planner = self.planner
            let draft: ResearchPlannerDraft = try await perform { try await planner.draft(for: input) }
            try checkActive()
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
        defer { busy = false; activeCancellation = nil }
        do {
            for query in plan.queries where !attempted.contains(query.id) {
                try Task.checkCancellation()
                try checkActive()
                try run.reserve([.queries: 1], at: clock.now())
                attempted.insert(query.id)
                try await perform { try await execute(query) }
                try checkActive()
            }
            try run.transition(to: .evaluating, at: clock.now())
        } catch {
            terminalize(error)
            throw error
        }
    }

    func collectionSnapshot() -> ResearchCollectionSnapshot {
        .init(runID: run.id, conversationID: run.conversationID, sources: collected)
    }

    /// Build only from this owner's accepted plan and charged collection. No transferred
    /// ledger can be adopted and no copied source text receives a second reservation.
    func buildEvidenceLedger(limits: ResearchEvidenceLimits) throws -> ResearchEvidenceLedger {
        guard !busy else { throw ResearchPlanningError.operationInProgress }
        guard collectionFinished, run.phase == .evaluating, let plan = acceptedPlan else {
            throw ResearchPlanningError.invalidPhase
        }
        do { try checkActive() }
        catch { terminalize(error); throw error }
        if let existing = evidenceLedger {
            guard existing.limits == limits else { throw ResearchEvidenceLedger.ValidationError.invalidBinding }
            return existing
        }
        do {
            let ledger = try ResearchEvidenceLedger.build(plan: plan, collection: collectionSnapshot(), limits: limits)
            try checkActive()
            if ledger.metadataCharacterCost > 0 {
                try run.reserve([.evidenceCharacters: ledger.metadataCharacterCost], at: clock.now())
            }
            evidenceLedger = ledger
            return ledger
        } catch {
            terminalize(error)
            throw error
        }
    }

    /// Coverage consumes only this owner's already charged ledger, without implicit ledger work.
    func buildCoverage(limits: ResearchCoverageLimits) throws -> ResearchCoverageReport {
        guard !busy else { throw ResearchPlanningError.operationInProgress }
        guard collectionFinished, run.phase == .evaluating, let plan = acceptedPlan, let ledger = evidenceLedger else {
            throw ResearchPlanningError.invalidPhase
        }
        do { try checkActive() } catch { terminalize(error); throw error }
        if let existing = coverageReport {
            guard existing.limits == limits else { throw ResearchCoverageReport.ValidationError.invalidBinding }
            return existing
        }
        do {
            let report = try ResearchCoverageReport.build(plan: plan, collection: collectionSnapshot(),
                ledger: ledger, evidenceLimits: ledger.limits, limits: limits)
            try checkActive()
            try run.reserve([.evidenceCharacters: report.metadataCharacterCost], at: clock.now())
            coverageReport = report
            return report
        } catch { terminalize(error); throw error }
    }

    /// Accepts one offline proposal. No model call, plan amendment, or additional query execution.
    /// Invalid drafts can be corrected before reservation; budget and clock failures terminalize.
    func buildRefinement(draft: ResearchRefinementDraft, limits: ResearchRefinementLimits) throws -> ResearchRefinementProposal {
        guard !busy else { throw ResearchPlanningError.operationInProgress }
        guard collectionFinished, run.phase == .evaluating, let plan = acceptedPlan,
              let ledger = evidenceLedger, let coverage = coverageReport else { throw ResearchPlanningError.invalidPhase }
        do { try checkActive() } catch { terminalize(error); throw error }
        if let existing = refinementProposal {
            guard existing.limits == limits else { throw ResearchRefinementProposal.ValidationError.invalidBinding }
        }
        let proposal: ResearchRefinementProposal
        do {
            proposal = try ResearchRefinementProposal.build(draft: draft, run: run, plan: plan,
                planningLimits: self.limits, collection: collectionSnapshot(), ledger: ledger, evidenceLimits: ledger.limits,
                coverage: coverage, coverageLimits: coverage.limits, attemptedQueryIDs: attempted, limits: limits)
        } catch {
            // A correctable offline error must not hide a deadline/cancellation crossed during validation.
            let validationError = error
            do { try checkActive() } catch { terminalize(error); throw error }
            throw validationError
        }
        do {
            try checkActive()
            if let existing = refinementProposal {
                guard existing == proposal else { throw ResearchRefinementProposal.ValidationError.invalidBinding }
                return existing
            }
            try run.reserve([.evidenceCharacters: proposal.metadataCharacterCost], at: clock.now())
            refinementProposal = proposal
            return proposal
        } catch let error as ResearchRefinementProposal.ValidationError { throw error }
        catch { terminalize(error); throw error }
    }

    func collect(using service: LocalResearchService, limits: ResearchCollectionLimits) async throws -> ResearchCollectionSnapshot {
        guard !busy else { throw ResearchPlanningError.operationInProgress }
        if collectionFinished, run.phase == .evaluating {
            do { try checkActive() } catch { terminalize(error); throw error }
            return collectionSnapshot()
        }
        guard run.phase == .collecting, let plan = acceptedPlan, attempted.isEmpty else {
            throw ResearchPlanningError.invalidPhase
        }
        busy = true
        let token = UUID(); operationToken = token
        defer { busy = false; activeCancellation = nil; operationToken = nil }
        let admission: ResearchHTTPAdmission = { kind in try await self.admit(kind, token: token) }
        do {
            for query in plan.queries {
                try checkCollection(token)
                try run.reserve([.queries: 1], at: clock.now())
                attempted.insert(query.id)
                let result: ResearchGatherResult
                do {
                    result = try await perform {
                        try await service.searchWithMetadata(query: query.text, limit: limits.resultsPerQuery, admission: admission)
                    }
                } catch LocalResearchError.noResults { continue }
                try checkCollection(token)
                for candidate in result.sources {
                    try checkCollection(token)
                    guard let key = try? limits.key(for: candidate.url) else { continue }
                    if let index = collected.firstIndex(where: { $0.requestedURLKey == key }) {
                        if !collected[index].queryIDs.contains(query.id) {
                            try run.reserve([.evidenceCharacters: query.id.count], at: clock.now())
                            collected[index].queryIDs.append(query.id)
                        }
                        continue
                    }
                    // A retained-source ceiling avoids starting HTTP that can never be retained.
                    guard collected.count < limits.maxSources,
                          run.usage[.sources]! < run.budget.limits[.sources]! else { continue }
                    var source = candidate, pageFetched = false
                    do {
                        source = try await perform { try await service.fetch(candidate, admission: admission) }
                        pageFetched = true
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as ResearchHTTPAdmissionError { throw error }
                    catch ResearchPlanningError.deadlineExceeded { throw ResearchPlanningError.deadlineExceeded }
                    catch let error as ResearchRun.ValidationError { throw error }
                    catch { /* Ordinary page failure retains the bounded search snippet. */ }
                    try checkCollection(token)
                    // Redirect URL identity remains whole; oversized redirects fall back to the requested snippet.
                    if (try? limits.key(for: source.url)) == nil { source = candidate; pageFetched = false }
                    let bounded = ResearchSource(id: source.id, title: limits.clipped(source.title), url: source.url,
                                                 snippet: limits.clipped(source.snippet), pageText: limits.clipped(source.pageText))
                    let record = ResearchCollectedSource(id: "source\(collected.count + 1)", requestedURLKey: key,
                        queryIDs: [query.id], provider: result.providerUsed, source: bounded, pageFetched: pageFetched)
                    try run.reserve([.sources: 1, .evidenceCharacters: record.characterCost], at: clock.now())
                    collected.append(record)
                }
            }
            try checkCollection(token)
            try run.transition(to: .evaluating, at: clock.now())
            collectionFinished = true
            return collectionSnapshot()
        } catch {
            terminalize(error)
            throw error
        }
    }

    private func checkCollection(_ token: UUID) throws {
        try checkActive()
        guard operationToken == token, run.phase == .collecting else { throw CancellationError() }
    }

    private func admit(_ kind: ResearchHTTPAdmissionKind, token: UUID) throws {
        try checkCollection(token)
        try run.reserve([kind == .page ? .fetches : .searchRequests: 1], at: clock.now())
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !run.phase.isTerminal else { throw CancellationError() }
        if try run.elapsed(at: clock.now()) >= run.budget.wallSeconds {
            throw ResearchRun.ValidationError.wallTimeExceeded
        }
    }

    private func perform<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try checkActive()
        let deadline = run.createdAt.addingTimeInterval(run.budget.wallSeconds)
        guard deadline.timeIntervalSinceReferenceDate.isFinite else { throw ResearchRun.ValidationError.invalidClock }
        let sleep = clock.sleepUntil
        let task = Task<Value, Error> {
            try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try Task.checkCancellation(); return try await operation() }
                group.addTask { try await sleep(deadline); try Task.checkCancellation(); throw ResearchPlanningError.deadlineExceeded }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
        activeCancellation = { task.cancel() }
        // Swift structured tasks wait for children on exit. Dependencies must honor cancellation;
        // this mechanism cancels cooperative work, it cannot forcibly kill an uncooperative API.
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func terminalTime() -> Date {
        let now = clock.now()
        return now.timeIntervalSinceReferenceDate.isFinite && now >= run.updatedAt ? now : run.updatedAt
    }

    private func terminalize(_ originalError: Error) {
        operationToken = nil
        let error = (originalError as? ResearchHTTPAdmissionError)?.cause ?? originalError
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
        case is ResearchPlan.ValidationError, is ResearchEvidenceLedger.ValidationError, is ResearchCoverageReport.ValidationError,
             is DecodingError, is ResearchPlannerError:
            reason = .invalidResponse
        case ResearchPlanningError.providerUnavailable, is LocalResearchError:
            reason = .providerUnavailable
        default: reason = .internalError
        }
        try? run.fail(reason, at: terminalTime())
    }
}
