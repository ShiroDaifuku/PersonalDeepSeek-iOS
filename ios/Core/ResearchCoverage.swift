import CryptoKit
import Foundation

struct ResearchCoverageLimits: Codable, Equatable, Sendable {
    let questions: Int
    let sourceReferences: Int
    let evidenceReferences: Int
    let encodedBytes: Int

    init(questions: Int = 32, sourceReferences: Int = 2_048,
         evidenceReferences: Int = 16_384, encodedBytes: Int = 1_048_576) throws {
        self.questions = questions; self.sourceReferences = sourceReferences
        self.evidenceReferences = evidenceReferences; self.encodedBytes = encodedBytes
        try validate()
    }
    fileprivate func validate() throws {
        guard (1...32).contains(questions), (1...2_048).contains(sourceReferences),
              (1...16_384).contains(evidenceReferences), (1...2_097_152).contains(encodedBytes) else {
            throw ResearchCoverageReport.ValidationError.invalidLimits
        }
    }
    private enum CodingKeys: String, CodingKey { case questions, sourceReferences, evidenceReferences, encodedBytes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questions = try c.decode(Int.self, forKey: .questions)
        sourceReferences = try c.decode(Int.self, forKey: .sourceReferences)
        evidenceReferences = try c.decode(Int.self, forKey: .evidenceReferences)
        encodedBytes = try c.decode(Int.self, forKey: .encodedBytes)
        try validate()
    }
}

/// Retrieval availability only: query associations never establish factual support or relevance.
/// Codable provides structural bounds, not authenticated history or permission to adopt a report.
struct ResearchCoverageReport: Codable, Equatable, Sendable {
    static let version = 1
    enum ValidationError: Error, Equatable { case invalidLimits, invalidBinding, invalidStructure, oversizedReport, unsupportedVersion }
    enum Availability: String, Codable, Sendable {
        case noAssociatedSources, sourcesWithoutEntries, pageEntries, snippetEntries, mixedEntries
    }
    enum Gap: String, Codable, Sendable {
        case noAssociatedSources, noRetainedEntries, snippetOnly, ledgerTruncated
    }
    struct Source: Codable, Equatable, Sendable {
        let id: String
        let origin: ResearchEvidenceLedger.Origin
        let ledgerTruncated: Bool
    }
    struct Evidence: Codable, Equatable, Sendable { let id: String; let sourceID: String }
    struct Question: Codable, Equatable, Sendable {
        let id: String
        let sourceIDs: [String]
        let pageEvidenceIDs: [String]
        let snippetEvidenceIDs: [String]
        let availability: Availability
        let gaps: [Gap]
    }
    let version: Int
    let runID: UUID
    let conversationID: UUID
    /// Hashes all ledger fields, including evidence text and the complete plan/collection digests.
    let ledgerContextDigest: String
    let limits: ResearchCoverageLimits
    let sources: [Source]
    let evidence: [Evidence]
    let questions: [Question]

    /// Every retained textual reference occurrence and label is new report metadata.
    /// No evidence body or question text is copied or charged again.
    var metadataCharacterCost: Int {
        ledgerContextDigest.count + sources.reduce(0) { $0 + $1.id.count + $1.origin.rawValue.count }
        + evidence.reduce(0) { $0 + $1.id.count + $1.sourceID.count }
        + questions.reduce(0) { total, row in
            total + row.id.count + row.sourceIDs.reduce(0) { $0 + $1.count }
            + row.pageEvidenceIDs.reduce(0) { $0 + $1.count }
            + row.snippetEvidenceIDs.reduce(0) { $0 + $1.count }
            + row.availability.rawValue.count + row.gaps.reduce(0) { $0 + $1.rawValue.count }
        }
    }

    static func build(plan: ResearchPlan, collection: ResearchCollectionSnapshot,
                      ledger: ResearchEvidenceLedger, evidenceLimits: ResearchEvidenceLimits,
                      limits: ResearchCoverageLimits) throws -> Self {
        try limits.validate()
        // A generic decoded ledger may have plausible IDs while containing forged provenance.
        guard ledger == (try ResearchEvidenceLedger.build(plan: plan, collection: collection, limits: evidenceLimits)) else {
            throw ValidationError.invalidBinding
        }
        let sources = ledger.sources.map { Source(id: $0.id, origin: $0.origin, ledgerTruncated: $0.ledgerTruncated) }
        let evidence = ledger.entries.map { Evidence(id: $0.id, sourceID: $0.sourceID) }
        let rows = plan.subquestions.map { question in
            let associated = ledger.sources.filter { $0.questionIDs.contains(question.id) }.map(\.id)
            return row(id: question.id, sourceIDs: associated, sources: sources, evidence: evidence)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(ledger)).map { String(format: "%02x", $0) }.joined()
        let report = Self(version: version, runID: plan.runID, conversationID: plan.conversationID,
                          ledgerContextDigest: digest, limits: limits, sources: sources, evidence: evidence, questions: rows)
        try report.validate()
        return report
    }

    static func decode(_ data: Data, plan: ResearchPlan, collection: ResearchCollectionSnapshot,
                       ledger: ResearchEvidenceLedger, evidenceLimits: ResearchEvidenceLimits,
                       limits: ResearchCoverageLimits) throws -> Self {
        try limits.validate()
        guard data.count <= limits.encodedBytes else { throw ValidationError.oversizedReport }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard decoded == (try build(plan: plan, collection: collection, ledger: ledger,
                                    evidenceLimits: evidenceLimits, limits: limits)) else { throw ValidationError.invalidBinding }
        return decoded
    }

    private static func row(id: String, sourceIDs: [String], sources: [Source], evidence: [Evidence]) -> Question {
        let associated = sources.filter { sourceIDs.contains($0.id) }
        let pages = Set(associated.filter { $0.origin == .fetchedPage }.map(\.id))
        let snippets = Set(associated.filter { $0.origin == .searchSnippet }.map(\.id))
        let pageIDs = evidence.filter { pages.contains($0.sourceID) }.map(\.id)
        let snippetIDs = evidence.filter { snippets.contains($0.sourceID) }.map(\.id)
        let availability: Availability = sourceIDs.isEmpty ? .noAssociatedSources
            : pageIDs.isEmpty && snippetIDs.isEmpty ? .sourcesWithoutEntries
            : pageIDs.isEmpty ? .snippetEntries : snippetIDs.isEmpty ? .pageEntries : .mixedEntries
        var gaps: [Gap] = []
        if sourceIDs.isEmpty { gaps.append(.noAssociatedSources) }
        if pageIDs.isEmpty && snippetIDs.isEmpty { gaps.append(.noRetainedEntries) }
        if pageIDs.isEmpty && !snippetIDs.isEmpty { gaps.append(.snippetOnly) }
        if associated.contains(where: \.ledgerTruncated) { gaps.append(.ledgerTruncated) }
        return Question(id: id, sourceIDs: sourceIDs, pageEvidenceIDs: pageIDs,
                        snippetEvidenceIDs: snippetIDs, availability: availability, gaps: gaps)
    }

    private init(version: Int, runID: UUID, conversationID: UUID, ledgerContextDigest: String,
                 limits: ResearchCoverageLimits, sources: [Source], evidence: [Evidence], questions: [Question]) {
        self.version = version; self.runID = runID; self.conversationID = conversationID
        self.ledgerContextDigest = ledgerContextDigest; self.limits = limits
        self.sources = sources; self.evidence = evidence; self.questions = questions
    }
    private func validate() throws {
        guard version == Self.version else { throw ValidationError.unsupportedVersion }
        try limits.validate()
        guard ledgerContextDigest.utf8.count == 64,
              ledgerContextDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              sources.count <= 64, evidence.count <= 512, !questions.isEmpty,
              questions.count <= limits.questions else { throw ValidationError.invalidStructure }
        for (index, source) in sources.enumerated() {
            guard source.id == "source\(index + 1)" else { throw ValidationError.invalidStructure }
        }
        var lastSource = -1
        for (index, entry) in evidence.enumerated() {
            guard entry.id == "evidence\(index + 1)", let sourceIndex = sources.firstIndex(where: { $0.id == entry.sourceID }),
                  sourceIndex >= lastSource else { throw ValidationError.invalidStructure }
            lastSource = sourceIndex
        }
        var sourceCount = 0, evidenceCount = 0
        for (index, question) in questions.enumerated() {
            guard question.id == "question\(index + 1)",
                  question.sourceIDs.count <= sources.count,
                  question.pageEvidenceIDs.count <= evidence.count,
                  question.snippetEvidenceIDs.count <= evidence.count,
                  question.sourceIDs.count <= limits.sourceReferences - sourceCount,
                  question.pageEvidenceIDs.count + question.snippetEvidenceIDs.count <= limits.evidenceReferences - evidenceCount,
                  question.sourceIDs == sources.filter({ question.sourceIDs.contains($0.id) }).map(\.id),
                  question == Self.row(id: question.id, sourceIDs: question.sourceIDs, sources: sources, evidence: evidence) else {
                throw ValidationError.invalidStructure
            }
            sourceCount += question.sourceIDs.count
            evidenceCount += question.pageEvidenceIDs.count + question.snippetEvidenceIDs.count
        }
        guard sourceCount <= limits.sourceReferences, evidenceCount <= limits.evidenceReferences else {
            throw ValidationError.invalidStructure
        }
        guard try JSONEncoder().encode(self).count <= limits.encodedBytes else { throw ValidationError.oversizedReport }
    }
    private enum CodingKeys: String, CodingKey { case version, runID, conversationID, ledgerContextDigest, limits, sources, evidence, questions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.version else { throw ValidationError.unsupportedVersion }
        runID = try c.decode(UUID.self, forKey: .runID); conversationID = try c.decode(UUID.self, forKey: .conversationID)
        ledgerContextDigest = try c.decode(String.self, forKey: .ledgerContextDigest)
        limits = try c.decode(ResearchCoverageLimits.self, forKey: .limits)
        sources = try c.decode([Source].self, forKey: .sources)
        evidence = try c.decode([Evidence].self, forKey: .evidence)
        questions = try c.decode([Question].self, forKey: .questions)
        try validate()
    }
}
