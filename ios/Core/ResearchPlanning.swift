import Foundation

/// Host-owned ceilings. Hard ceilings keep a misconfigured caller from removing the bound.
struct ResearchPlanningLimits: Codable, Equatable, Sendable {
    let draftBytes: Int
    let planBytes: Int
    let subquestions: Int
    let queries: Int
    let questionCharacters: Int
    let queryCharacters: Int

    init(draftBytes: Int = 32_768, planBytes: Int = 65_536, subquestions: Int = 8,
         queries: Int = 24, questionCharacters: Int = 1_000, queryCharacters: Int = 500) throws {
        self.draftBytes = draftBytes
        self.planBytes = planBytes
        self.subquestions = subquestions
        self.queries = queries
        self.questionCharacters = questionCharacters
        self.queryCharacters = queryCharacters
        try validate()
    }

    fileprivate func validate() throws {
        guard (1...262_144).contains(draftBytes), (1...524_288).contains(planBytes),
              (1...32).contains(subquestions), (1...128).contains(queries),
              (1...4_000).contains(questionCharacters), (1...500).contains(queryCharacters) else {
            throw ResearchPlan.ValidationError.invalidLimits
        }
    }

    private enum CodingKeys: String, CodingKey {
        case draftBytes, planBytes, subquestions, queries, questionCharacters, queryCharacters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        draftBytes = try c.decode(Int.self, forKey: .draftBytes)
        planBytes = try c.decode(Int.self, forKey: .planBytes)
        subquestions = try c.decode(Int.self, forKey: .subquestions)
        queries = try c.decode(Int.self, forKey: .queries)
        questionCharacters = try c.decode(Int.self, forKey: .questionCharacters)
        queryCharacters = try c.decode(Int.self, forKey: .queryCharacters)
        try validate()
    }
}

/// Untrusted planner output has no IDs, budgets, permissions, URLs or profile context.
struct ResearchPlannerDraft: Codable, Equatable, Sendable {
    struct Subquestion: Codable, Equatable, Sendable {
        let question: String
        let queries: [String]
    }
    let subquestions: [Subquestion]

    static func decode(_ data: Data, limits: ResearchPlanningLimits) throws -> Self {
        try limits.validate()
        guard data.count <= limits.draftBytes else { throw ResearchPlan.ValidationError.oversizedDraft }
        let draft = try JSONDecoder().decode(Self.self, from: data)
        try draft.validateSize(limits: limits)
        return draft
    }

    fileprivate func validateSize(limits: ResearchPlanningLimits) throws {
        guard !subquestions.isEmpty, subquestions.count <= limits.subquestions else {
            throw ResearchPlan.ValidationError.invalidQuestions
        }
        var count = 0
        for question in subquestions {
            guard !question.queries.isEmpty, question.queries.count <= limits.queries else {
                throw ResearchPlan.ValidationError.invalidQueries
            }
            count += question.queries.count
            guard count <= limits.queries else { throw ResearchPlan.ValidationError.invalidQueries }
            // Check raw text too: whitespace must not be an unlimited hidden payload.
            guard question.question.count <= limits.questionCharacters,
                  question.queries.allSatisfy({ $0.count <= limits.queryCharacters }) else {
                throw ResearchPlan.ValidationError.oversizedText
            }
        }
        guard try JSONEncoder().encode(self).count <= limits.draftBytes else {
            throw ResearchPlan.ValidationError.oversizedDraft
        }
    }
}

struct ResearchPlan: Codable, Equatable, Sendable {
    static let version = 1
    enum ValidationError: Error, Equatable {
        case invalidLimits, oversizedDraft, oversizedPlan, oversizedText, invalidText
        case invalidQuestions, invalidQueries, invalidAssociations, invalidBinding, unsupportedVersion
    }
    struct Subquestion: Codable, Equatable, Sendable {
        let id: String
        let question: String
        let queryIDs: [String]
    }
    struct Query: Codable, Equatable, Sendable {
        let id: String
        let text: String
    }
    let version: Int
    let runID: UUID
    let conversationID: UUID
    let originalQuestion: String
    let limits: ResearchPlanningLimits
    let subquestions: [Subquestion]
    let queries: [Query]

    init(draft: ResearchPlannerDraft, run: ResearchRun, limits: ResearchPlanningLimits) throws {
        try limits.validate()
        try draft.validateSize(limits: limits)
        version = Self.version
        runID = run.id
        conversationID = run.conversationID
        originalQuestion = run.query
        self.limits = limits
        var questions: [Subquestion] = []
        var unique: [Query] = []
        var keys: [String: String] = [:]
        for (index, item) in draft.subquestions.enumerated() {
            let text = try Self.normalized(item.question)
            var associations: [String] = []
            for raw in item.queries {
                let query = try Self.normalized(raw)
                let key = Self.key(query)
                let id: String
                if let existing = keys[key] { id = existing }
                else {
                    id = "query\(unique.count + 1)"
                    keys[key] = id
                    unique.append(Query(id: id, text: query))
                }
                if !associations.contains(id) { associations.append(id) }
            }
            questions.append(Subquestion(id: "question\(index + 1)", question: text, queryIDs: associations))
        }
        subquestions = questions
        queries = unique
        try validate()
        guard try JSONEncoder().encode(self).count <= limits.planBytes else { throw ValidationError.oversizedPlan }
    }

    /// Call this at a Data boundary; Decoder itself cannot reveal the input's encoded byte size.
    static func decode(_ data: Data, for run: ResearchRun, limits: ResearchPlanningLimits) throws -> Self {
        try limits.validate()
        guard data.count <= limits.planBytes else { throw ValidationError.oversizedPlan }
        let plan = try JSONDecoder().decode(Self.self, from: data)
        guard plan.runID == run.id, plan.conversationID == run.conversationID,
              plan.originalQuestion == run.query, plan.limits == limits else {
            throw ValidationError.invalidBinding
        }
        return plan
    }

    static func normalized(_ text: String) throws -> String {
        for scalar in text.unicodeScalars {
            // Newlines/tabs are ordinary separators. Reject all other controls and format
            // characters, including zero-width and bidi controls. ZWJ/ZWNJ are retained
            // for emoji sequences and scripts that use joining semantics.
            switch scalar.properties.generalCategory {
            case .control:
                guard scalar == "\t" || scalar == "\n" || scalar == "\r" else { throw ValidationError.invalidText }
            case .format:
                guard scalar == "\u{200C}" || scalar == "\u{200D}" else { throw ValidationError.invalidText }
            default: break
            }
        }
        let result = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .precomposedStringWithCanonicalMapping
        guard !result.isEmpty, result.unicodeScalars.contains(where: {
            $0.properties.generalCategory != .format
        }) else { throw ValidationError.invalidText }
        return result
    }

    static func key(_ text: String) -> String { text.lowercased().precomposedStringWithCanonicalMapping }

    private func validate() throws {
        guard version == Self.version else { throw ValidationError.unsupportedVersion }
        try limits.validate()
        guard !originalQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.invalidBinding
        }
        guard !subquestions.isEmpty, subquestions.count <= limits.subquestions else { throw ValidationError.invalidQuestions }
        guard !queries.isEmpty, queries.count <= limits.queries else { throw ValidationError.invalidQueries }
        var keys = Set<String>()
        for (i, query) in queries.enumerated() {
            guard query.id == "query\(i + 1)", query.text.count <= limits.queryCharacters,
                  try Self.normalized(query.text) == query.text, keys.insert(Self.key(query.text)).inserted else {
                throw ValidationError.invalidQueries
            }
        }
        let ids = Set(queries.map(\.id))
        var used = Set<String>()
        var associations = 0
        for (i, question) in subquestions.enumerated() {
            guard question.id == "question\(i + 1)", question.question.count <= limits.questionCharacters,
                  try Self.normalized(question.question) == question.question else { throw ValidationError.invalidQuestions }
            let references = Set(question.queryIDs)
            associations += references.count
            guard !references.isEmpty, references.count == question.queryIDs.count,
                  references.isSubset(of: ids), associations <= limits.queries else { throw ValidationError.invalidAssociations }
            used.formUnion(references)
        }
        guard used == ids else { throw ValidationError.invalidAssociations }
    }

    private enum CodingKeys: String, CodingKey { case version, runID, conversationID, originalQuestion, limits, subquestions, queries }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        runID = try c.decode(UUID.self, forKey: .runID)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        originalQuestion = try c.decode(String.self, forKey: .originalQuestion)
        limits = try c.decode(ResearchPlanningLimits.self, forKey: .limits)
        subquestions = try c.decode([Subquestion].self, forKey: .subquestions)
        queries = try c.decode([Query].self, forKey: .queries)
        try validate()
        guard try JSONEncoder().encode(self).count <= limits.planBytes else { throw ValidationError.oversizedPlan }
    }
}

struct ResearchPlanningInput: Equatable, Sendable {
    let runID: UUID
    let question: String
    let limits: ResearchPlanningLimits
}

protocol ResearchPlanning: Sendable {
    var reservationCosts: [ResearchRun.Resource: Int] { get }
    /// Dependencies must cooperate with task cancellation and declare the full per-call reservation.
    func draft(for input: ResearchPlanningInput) async throws -> ResearchPlannerDraft
}

extension ResearchPlanning {
    var reservationCosts: [ResearchRun.Resource: Int] { [:] }
}

struct FixtureResearchPlanner: ResearchPlanning {
    let fixture: ResearchPlannerDraft
    func draft(for input: ResearchPlanningInput) async throws -> ResearchPlannerDraft {
        try Task.checkCancellation()
        return fixture
    }
}
