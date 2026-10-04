import CryptoKit
import Foundation

struct ResearchRefinementLimits: Codable, Equatable, Sendable {
    let draftBytes: Int
    let proposalBytes: Int
    let targets: Int
    let queries: Int
    let queryCharacters: Int
    let queryBytes: Int

    init(draftBytes: Int = 32_768, proposalBytes: Int = 65_536, targets: Int = 8,
         queries: Int = 24, queryCharacters: Int = 500, queryBytes: Int = 2_000) throws {
        self.draftBytes = draftBytes; self.proposalBytes = proposalBytes
        self.targets = targets; self.queries = queries
        self.queryCharacters = queryCharacters; self.queryBytes = queryBytes
        try validate()
    }
    fileprivate func validate() throws {
        guard (1...262_144).contains(draftBytes), (1...524_288).contains(proposalBytes),
              (1...32).contains(targets), (1...128).contains(queries),
              (1...500).contains(queryCharacters), (1...8_000).contains(queryBytes) else {
            throw ResearchRefinementProposal.ValidationError.invalidLimits
        }
    }
    private enum CodingKeys: String, CodingKey { case draftBytes, proposalBytes, targets, queries, queryCharacters, queryBytes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        draftBytes = try c.decode(Int.self, forKey: .draftBytes)
        proposalBytes = try c.decode(Int.self, forKey: .proposalBytes)
        targets = try c.decode(Int.self, forKey: .targets); queries = try c.decode(Int.self, forKey: .queries)
        queryCharacters = try c.decode(Int.self, forKey: .queryCharacters)
        queryBytes = try c.decode(Int.self, forKey: .queryBytes)
        try validate()
    }
}

/// Offline, untrusted suggestions. Gap labels are retrieval diagnostics, not factual claims.
struct ResearchRefinementDraft: Codable, Equatable, Sendable {
    struct Target: Codable, Equatable, Sendable {
        let questionID: String
        let gaps: [ResearchCoverageReport.Gap]
        let queries: [String]
    }
    let targets: [Target]

    static func decode(_ data: Data, limits: ResearchRefinementLimits) throws -> Self {
        try limits.validate()
        guard data.count <= limits.draftBytes else { throw ResearchRefinementProposal.ValidationError.oversizedDraft }
        let draft = try JSONDecoder().decode(Self.self, from: data)
        try draft.validate(limits)
        return draft
    }
    fileprivate func validate(_ limits: ResearchRefinementLimits) throws {
        guard targets.count <= limits.targets else { throw ResearchRefinementProposal.ValidationError.invalidTargets }
        var associations = 0
        var seen = Set<String>()
        for target in targets {
            guard ResearchRefinementProposal.validID(target.questionID, prefix: "question", maximum: 32),
                  seen.insert(target.questionID).inserted, !target.gaps.isEmpty, target.gaps.count <= 4,
                  Set(target.gaps).count == target.gaps.count else { throw ResearchRefinementProposal.ValidationError.invalidTargets }
            guard !target.queries.isEmpty, target.queries.count <= limits.queries - associations else {
                throw ResearchRefinementProposal.ValidationError.invalidQueries
            }
            associations += target.queries.count
            for text in target.queries {
                guard text.count <= limits.queryCharacters, text.utf8.count <= limits.queryBytes else {
                    throw ResearchRefinementProposal.ValidationError.oversizedText
                }
            }
        }
        guard try JSONEncoder().encode(self).count <= limits.draftBytes else {
            throw ResearchRefinementProposal.ValidationError.oversizedDraft
        }
    }
}

/// Bounded proposal only: this does not amend the accepted plan or authorize execution.
/// Generic Codable checks structure; host-context decoding verifies the complete projection.
struct ResearchRefinementProposal: Codable, Equatable, Sendable {
    static let version = 1
    enum ValidationError: Error, Equatable {
        case invalidLimits, invalidBinding, invalidTargets, invalidQueries, invalidStructure
        case oversizedDraft, oversizedProposal, oversizedText, unsupportedVersion
    }
    struct Target: Codable, Equatable, Sendable {
        let questionID: String
        let gaps: [ResearchCoverageReport.Gap]
        let queryIDs: [String]
    }
    let version: Int
    let runID: UUID
    let conversationID: UUID
    let contextDigest: String
    let baselineQueryCount: Int
    let baselineQuestionCount: Int
    let baselineAssociationCount: Int
    let queryCapacity: Int
    let attemptedQueryIDs: [String]
    let limits: ResearchRefinementLimits
    let queries: [ResearchPlan.Query]
    let targets: [Target]

    /// All retained textual occurrences are novel proposal metadata, including query text.
    /// Existing question/source/evidence bodies are neither copied nor charged again.
    var metadataCharacterCost: Int {
        var total = contextDigest.count
        for id in attemptedQueryIDs { total += id.count }
        for query in queries { total += query.id.count; total += query.text.count }
        for target in targets {
            total += target.questionID.count
            for gap in target.gaps { total += gap.rawValue.count }
            for id in target.queryIDs { total += id.count }
        }
        return total
    }

    static func build(draft: ResearchRefinementDraft, run: ResearchRun, plan: ResearchPlan,
                      planningLimits: ResearchPlanningLimits, collection: ResearchCollectionSnapshot,
                      ledger: ResearchEvidenceLedger, evidenceLimits: ResearchEvidenceLimits,
                      coverage: ResearchCoverageReport, coverageLimits: ResearchCoverageLimits,
                      attemptedQueryIDs: Set<String>, limits: ResearchRefinementLimits) throws -> Self {
        try limits.validate(); try draft.validate(limits)
        guard plan.runID == run.id, plan.conversationID == run.conversationID,
              plan.originalQuestion == run.query, plan.limits == planningLimits else { throw ValidationError.invalidBinding }
        guard coverage == (try ResearchCoverageReport.build(plan: plan, collection: collection,
            ledger: ledger, evidenceLimits: evidenceLimits, limits: coverageLimits)) else { throw ValidationError.invalidBinding }
        let knownIDs = Set(plan.queries.map(\.id))
        guard attemptedQueryIDs.isSubset(of: knownIDs) else { throw ValidationError.invalidBinding }
        let canonicalAttempts = plan.queries.filter { attemptedQueryIDs.contains($0.id) }.map(\.id)
        let previousKeys = Set(plan.queries.map { ResearchPlan.key($0.text) })
        var novel: [ResearchPlan.Query] = [], associations: [Target] = [], keys = Set<String>()
        for target in draft.targets {
            guard let question = coverage.questions.first(where: { $0.id == target.questionID }),
                  target.gaps.allSatisfy({ question.gaps.contains($0) }) else { throw ValidationError.invalidTargets }
            let gaps = question.gaps.filter { target.gaps.contains($0) }
            var ids: [String] = []
            for raw in target.queries {
                let text = try ResearchPlan.normalized(raw)
                guard text.count <= limits.queryCharacters, text.utf8.count <= limits.queryBytes else { throw ValidationError.oversizedText }
                let key = ResearchPlan.key(text)
                guard !previousKeys.contains(key), keys.insert(key).inserted else { throw ValidationError.invalidQueries }
                let id = "query\(plan.queries.count + novel.count + 1)"
                novel.append(.init(id: id, text: text)); ids.append(id)
            }
            associations.append(.init(questionID: target.questionID, gaps: gaps, queryIDs: ids))
        }
        // Canonical target order is the accepted plan's order, independent of draft ordering.
        let ordered = plan.subquestions.compactMap { question in associations.first { $0.questionID == question.id } }
        var baselineAssociations = 0
        for question in plan.subquestions { baselineAssociations += question.queryIDs.count }
        guard novel.count <= planningLimits.queries - plan.queries.count,
              novel.count <= planningLimits.queries - baselineAssociations else { throw ValidationError.invalidQueries }
        let context = Context(run: run, coverage: coverage, attempts: canonicalAttempts, limits: limits, draft: draft)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(context)).map { String(format: "%02x", $0) }.joined()
        let result = Self(version: version, runID: run.id, conversationID: run.conversationID,
            contextDigest: digest, baselineQueryCount: plan.queries.count, baselineQuestionCount: plan.subquestions.count,
            baselineAssociationCount: baselineAssociations, queryCapacity: planningLimits.queries,
            attemptedQueryIDs: canonicalAttempts, limits: limits, queries: novel, targets: ordered)
        try result.validate()
        return result
    }

    static func decode(_ data: Data, draft: ResearchRefinementDraft, run: ResearchRun, plan: ResearchPlan,
                       planningLimits: ResearchPlanningLimits, collection: ResearchCollectionSnapshot,
                       ledger: ResearchEvidenceLedger, evidenceLimits: ResearchEvidenceLimits,
                       coverage: ResearchCoverageReport, coverageLimits: ResearchCoverageLimits,
                       attemptedQueryIDs: Set<String>, limits: ResearchRefinementLimits) throws -> Self {
        try limits.validate()
        guard data.count <= limits.proposalBytes else { throw ValidationError.oversizedProposal }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        let expected = try build(draft: draft, run: run, plan: plan, planningLimits: planningLimits,
            collection: collection, ledger: ledger, evidenceLimits: evidenceLimits, coverage: coverage,
            coverageLimits: coverageLimits, attemptedQueryIDs: attemptedQueryIDs, limits: limits)
        guard decoded == expected else { throw ValidationError.invalidBinding }
        return decoded
    }

    private struct Context: Encodable {
        let runID: UUID
        let conversationID: UUID
        let originalQuestion: String
        let createdAt: Date
        struct BudgetRow: Encodable { let resource: ResearchRun.Resource; let limit: Int }
        let budgetRows: [BudgetRow]
        let wallSeconds: TimeInterval
        let coverage: ResearchCoverageReport
        let attempts: [String]
        let limits: ResearchRefinementLimits
        let draft: ResearchRefinementDraft
        init(run: ResearchRun, coverage: ResearchCoverageReport, attempts: [String], limits: ResearchRefinementLimits,
             draft: ResearchRefinementDraft) {
            runID = run.id; conversationID = run.conversationID; originalQuestion = run.query
            createdAt = run.createdAt
            budgetRows = ResearchRun.Resource.allCases.map { BudgetRow(resource: $0, limit: run.budget.limits[$0]!) }
            wallSeconds = run.budget.wallSeconds; self.coverage = coverage
            self.attempts = attempts; self.limits = limits; self.draft = draft
        }
    }
    private init(version: Int, runID: UUID, conversationID: UUID, contextDigest: String,
                 baselineQueryCount: Int, baselineQuestionCount: Int, baselineAssociationCount: Int,
                 queryCapacity: Int, attemptedQueryIDs: [String],
                 limits: ResearchRefinementLimits, queries: [ResearchPlan.Query], targets: [Target]) {
        self.version = version; self.runID = runID; self.conversationID = conversationID
        self.contextDigest = contextDigest; self.baselineQueryCount = baselineQueryCount
        self.baselineQuestionCount = baselineQuestionCount; self.baselineAssociationCount = baselineAssociationCount
        self.queryCapacity = queryCapacity; self.attemptedQueryIDs = attemptedQueryIDs
        self.limits = limits; self.queries = queries; self.targets = targets
    }
    fileprivate static func validID(_ value: String, prefix: String, maximum: Int) -> Bool {
        guard value.hasPrefix(prefix), let number = Int(value.dropFirst(prefix.count)), (1...maximum).contains(number) else { return false }
        return value == "\(prefix)\(number)"
    }
    private func validate() throws {
        guard version == Self.version else { throw ValidationError.unsupportedVersion }
        try limits.validate()
        guard (1...128).contains(baselineQueryCount), (1...32).contains(baselineQuestionCount),
              (baselineQueryCount...128).contains(queryCapacity), queries.count <= queryCapacity - baselineQueryCount,
              (baselineQueryCount...queryCapacity).contains(baselineAssociationCount),
              queries.count <= queryCapacity - baselineAssociationCount,
              contextDigest.utf8.count == 64,
              contextDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              queries.count <= limits.queries, targets.isEmpty == queries.isEmpty,
              targets.count <= limits.targets,
              attemptedQueryIDs.count <= baselineQueryCount else { throw ValidationError.invalidStructure }
        var previousAttempt = 0
        for id in attemptedQueryIDs {
            guard Self.validID(id, prefix: "query", maximum: baselineQueryCount),
                  let number = Int(id.dropFirst(5)), number > previousAttempt else { throw ValidationError.invalidStructure }
            previousAttempt = number
        }
        var keys = Set<String>()
        for (index, query) in queries.enumerated() {
            guard query.id == "query\(baselineQueryCount + index + 1)",
                  query.text.count <= limits.queryCharacters, query.text.utf8.count <= limits.queryBytes,
                  try ResearchPlan.normalized(query.text) == query.text,
                  keys.insert(ResearchPlan.key(query.text)).inserted else { throw ValidationError.invalidQueries }
        }
        let known = Set(queries.map(\.id))
        var used = Set<String>(), count = 0, lastQuestion = 0
        let gapOrder: [ResearchCoverageReport.Gap] = [.noAssociatedSources, .noRetainedEntries, .snippetOnly, .ledgerTruncated]
        for target in targets {
            guard Self.validID(target.questionID, prefix: "question", maximum: baselineQuestionCount),
                  let number = Int(target.questionID.dropFirst(8)), number > lastQuestion,
                  !target.gaps.isEmpty, target.gaps.count <= 4,
                  target.gaps == gapOrder.filter({ target.gaps.contains($0) }),
                  !target.queryIDs.isEmpty, target.queryIDs.count <= limits.queries - count,
                  Set(target.queryIDs).count == target.queryIDs.count,
                  Set(target.queryIDs).isSubset(of: known), used.isDisjoint(with: target.queryIDs) else { throw ValidationError.invalidTargets }
            lastQuestion = number; count += target.queryIDs.count; used.formUnion(target.queryIDs)
        }
        guard used == known else { throw ValidationError.invalidQueries }
        guard try JSONEncoder().encode(self).count <= limits.proposalBytes else { throw ValidationError.oversizedProposal }
    }
    private enum CodingKeys: String, CodingKey {
        case version, runID, conversationID, contextDigest, baselineQueryCount, baselineQuestionCount, baselineAssociationCount, queryCapacity
        case attemptedQueryIDs, limits, queries, targets
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.version else { throw ValidationError.unsupportedVersion }
        runID = try c.decode(UUID.self, forKey: .runID); conversationID = try c.decode(UUID.self, forKey: .conversationID)
        contextDigest = try c.decode(String.self, forKey: .contextDigest)
        baselineQueryCount = try c.decode(Int.self, forKey: .baselineQueryCount)
        baselineQuestionCount = try c.decode(Int.self, forKey: .baselineQuestionCount)
        baselineAssociationCount = try c.decode(Int.self, forKey: .baselineAssociationCount)
        queryCapacity = try c.decode(Int.self, forKey: .queryCapacity)
        attemptedQueryIDs = try c.decode([String].self, forKey: .attemptedQueryIDs)
        limits = try c.decode(ResearchRefinementLimits.self, forKey: .limits)
        queries = try c.decode([ResearchPlan.Query].self, forKey: .queries)
        targets = try c.decode([Target].self, forKey: .targets)
        try validate()
    }
}
