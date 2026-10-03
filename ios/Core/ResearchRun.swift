import Foundation

/// Foundation-only lifecycle metadata. It deliberately contains no evidence, model output or memory writes.
struct ResearchRun: Codable, Equatable, Sendable {
    static let checkpointVersion = 1

    enum Phase: String, Codable, Sendable, CaseIterable {
        case queued, planning, collecting, evaluating, synthesizing, completed, cancelled, failed
        var isTerminal: Bool { self == .completed || self == .cancelled || self == .failed }
    }

    enum Resource: String, Codable, Sendable, CaseIterable {
        case rounds, queries, sources, fetches, evidenceCharacters, synthesisTokens
    }

    enum Failure: String, Codable, Sendable {
        case budgetExhausted, providerUnavailable, invalidResponse, internalError
    }

    enum ValidationError: Error, Equatable {
        case unsupportedVersion(Int), invalidQuery, invalidBudget, invalidCheckpoint
        case invalidTransition(Phase, Phase), terminalRun, invalidReservation
        case budgetExceeded(Resource), wallTimeExceeded, invalidClock
    }

    struct Budget: Codable, Equatable, Sendable {
        let limits: [Resource: Int]
        let wallSeconds: TimeInterval

        init(rounds: Int, queries: Int, sources: Int, fetches: Int,
             evidenceCharacters: Int, synthesisTokens: Int, wallSeconds: TimeInterval) throws {
            limits = [.rounds: rounds, .queries: queries, .sources: sources, .fetches: fetches,
                      .evidenceCharacters: evidenceCharacters, .synthesisTokens: synthesisTokens]
            self.wallSeconds = wallSeconds
            try validate()
        }

        fileprivate func validate() throws {
            guard limits.count == Resource.allCases.count,
                  Resource.allCases.allSatisfy({ (limits[$0] ?? 0) > 0 }),
                  wallSeconds.isFinite, wallSeconds > 0 else { throw ValidationError.invalidBudget }
        }

        private enum CodingKeys: String, CodingKey { case limits, wallSeconds }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            limits = try values.decode([Resource: Int].self, forKey: .limits)
            wallSeconds = try values.decode(TimeInterval.self, forKey: .wallSeconds)
            try validate()
        }
    }

    let version: Int
    let id: UUID
    let conversationID: UUID
    let query: String
    let budget: Budget
    let createdAt: Date
    private(set) var updatedAt: Date
    private(set) var phase: Phase
    private(set) var usage: [Resource: Int]
    private(set) var failure: Failure?

    /// Callers supply the clock so lifecycle tests and future orchestration are deterministic.
    init(id: UUID = UUID(), conversationID: UUID, query: String, budget: Budget, now: Date) throws {
        version = Self.checkpointVersion
        self.id = id
        self.conversationID = conversationID
        self.query = query
        self.budget = budget
        createdAt = now
        updatedAt = now
        phase = .queued
        usage = Dictionary(uniqueKeysWithValues: Resource.allCases.map { ($0, 0) })
        failure = nil
        try validate()
    }

    /// Wall time includes time between checkpoints, including app shutdown. A restored run does not get a fresh budget.
    func elapsed(at now: Date) throws -> TimeInterval {
        guard now.timeIntervalSinceReferenceDate.isFinite, now >= updatedAt else {
            throw ValidationError.invalidClock
        }
        let interval = now.timeIntervalSince(createdAt)
        guard interval.isFinite else { throw ValidationError.invalidClock }
        return interval
    }

    private func checkActive(at now: Date, enforceDeadline: Bool = true) throws {
        guard !phase.isTerminal else { throw ValidationError.terminalRun }
        let elapsed = try elapsed(at: now)
        if enforceDeadline && elapsed >= budget.wallSeconds { throw ValidationError.wallTimeExceeded }
    }

    /// Reservations are cumulative attempted work, never refundable. All dimensions commit together or none do.
    mutating func reserve(_ costs: [Resource: Int], at now: Date) throws {
        try checkActive(at: now)
        guard !costs.isEmpty, costs.values.allSatisfy({ $0 >= 0 }), costs.values.contains(where: { $0 > 0 }) else {
            throw ValidationError.invalidReservation
        }
        var proposed = usage
        for resource in Resource.allCases {
            guard let amount = costs[resource] else { continue }
            let (sum, overflow) = usage[resource]!.addingReportingOverflow(amount)
            guard !overflow, sum <= budget.limits[resource]! else { throw ValidationError.budgetExceeded(resource) }
            proposed[resource] = sum
        }
        usage = proposed
        updatedAt = now
    }

    /// Transitions track lifecycle only; orchestration must reserve work before execution.
    /// Moving through phases does not itself consume any resource budget.
    mutating func transition(to next: Phase, at now: Date) throws {
        try checkActive(at: now)
        let allowed: Bool
        switch (phase, next) {
        case (.queued, .planning), (.planning, .collecting), (.collecting, .evaluating),
             (.evaluating, .collecting), (.evaluating, .synthesizing), (.synthesizing, .completed):
            allowed = true
        default: allowed = false
        }
        guard allowed else { throw ValidationError.invalidTransition(phase, next) }
        phase = next
        updatedAt = now
    }

    /// Cancellation and failure can record a terminal outcome even after the wall deadline.
    mutating func cancel(at now: Date) throws {
        try checkActive(at: now, enforceDeadline: false)
        phase = .cancelled
        updatedAt = now
    }

    mutating func fail(_ reason: Failure, at now: Date) throws {
        try checkActive(at: now, enforceDeadline: false)
        phase = .failed
        failure = reason
        updatedAt = now
    }

    fileprivate func validate() throws {
        guard version == Self.checkpointVersion else { throw ValidationError.unsupportedVersion(version) }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.invalidQuery }
        try budget.validate()
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite, updatedAt >= createdAt,
              updatedAt.timeIntervalSince(createdAt).isFinite,
              usage.count == Resource.allCases.count,
              Resource.allCases.allSatisfy({ resource in
                  guard let count = usage[resource], let ceiling = budget.limits[resource] else { return false }
                  return count >= 0 && count <= ceiling
              }), (phase == .failed) == (failure != nil) else { throw ValidationError.invalidCheckpoint }
        if phase != .cancelled && phase != .failed && updatedAt.timeIntervalSince(createdAt) >= budget.wallSeconds {
            throw ValidationError.invalidCheckpoint
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, conversationID, query, budget, createdAt, updatedAt, phase, usage, failure
    }

    /// Every Codable entry point validates checkpoints; synthesized decoding would bypass constructor invariants.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        id = try values.decode(UUID.self, forKey: .id)
        conversationID = try values.decode(UUID.self, forKey: .conversationID)
        query = try values.decode(String.self, forKey: .query)
        budget = try values.decode(Budget.self, forKey: .budget)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        phase = try values.decode(Phase.self, forKey: .phase)
        usage = try values.decode([Resource: Int].self, forKey: .usage)
        failure = try values.decodeIfPresent(Failure.self, forKey: .failure)
        try validate()
    }
}
