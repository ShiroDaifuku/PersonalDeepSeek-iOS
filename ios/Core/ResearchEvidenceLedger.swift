import CryptoKit
import Foundation

/// Ephemeral host bounds, not provider-selected settings or a claim about heap usage.
struct ResearchEvidenceLimits: Codable, Equatable, Sendable {
    let sources: Int
    let entries: Int
    let segmentCharacters: Int
    let segmentBytes: Int
    let textCharacters: Int
    let encodedBytes: Int

    init(sources: Int = 64, entries: Int = 256, segmentCharacters: Int = 1_000,
         segmentBytes: Int = 4_000, textCharacters: Int = 100_000, encodedBytes: Int = 1_048_576) throws {
        self.sources = sources; self.entries = entries
        self.segmentCharacters = segmentCharacters; self.segmentBytes = segmentBytes
        self.textCharacters = textCharacters; self.encodedBytes = encodedBytes
        try validate()
    }

    fileprivate func validate() throws {
        guard (1...64).contains(sources), (1...512).contains(entries),
              (1...4_000).contains(segmentCharacters), (1...16_000).contains(segmentBytes),
              (1...200_000).contains(textCharacters), (1...2_097_152).contains(encodedBytes) else {
            throw ResearchEvidenceLedger.ValidationError.invalidLimits
        }
    }

    private enum CodingKeys: String, CodingKey { case sources, entries, segmentCharacters, segmentBytes, textCharacters, encodedBytes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decode(Int.self, forKey: .sources); entries = try c.decode(Int.self, forKey: .entries)
        segmentCharacters = try c.decode(Int.self, forKey: .segmentCharacters)
        segmentBytes = try c.decode(Int.self, forKey: .segmentBytes)
        textCharacters = try c.decode(Int.self, forKey: .textCharacters)
        encodedBytes = try c.decode(Int.self, forKey: .encodedBytes)
        try validate()
    }
}

/// Structurally bounded, untrusted evidence. Codable is neither authenticated history nor persistence.
struct ResearchEvidenceLedger: Codable, Equatable, Sendable {
    static let version = 1
    enum ValidationError: Error, Equatable {
        case invalidLimits, invalidBinding, invalidCollection, invalidStructure, oversizedLedger, unsupportedVersion
    }
    enum Origin: String, Codable, Sendable { case fetchedPage, searchSnippet }
    struct Source: Codable, Equatable, Sendable {
        let id: String
        let requestedURLKey: String
        let finalURL: String
        let title: String
        let queryIDs: [String]
        let questionIDs: [String]
        /// Only this query's first retained observation has a known provider; subsequent links do not.
        let firstObservationQueryID: String
        let firstObservationProvider: ResearchProvider
        let origin: Origin
        let collectedCharacters: Int
        /// Additional ledger prefix loss, never a claim about the complete original webpage.
        let ledgerTruncated: Bool
    }
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let sourceID: String
        /// Character offset in the selected, already bounded collection field.
        let characterOffset: Int
        let text: String
    }
    let version: Int
    let runID: UUID
    let conversationID: UUID
    /// Canonical context identities, not signatures or proof of prior accounting.
    let planContextDigest: String
    let collectionContextDigest: String
    let limits: ResearchEvidenceLimits
    let sources: [Source]
    let entries: [Entry]

    /// Only generated textual metadata is new work. Collection fields and copied evidence text
    /// already have collection reservations. This character budget is not a memory/billing meter.
    var metadataCharacterCost: Int {
        planContextDigest.count + collectionContextDigest.count
        + sources.reduce(0) { $0 + $1.questionIDs.reduce(0) { $0 + $1.count }
            + $1.firstObservationQueryID.count + $1.origin.rawValue.count }
        + entries.reduce(0) { $0 + $1.id.count + $1.sourceID.count }
    }

    static func build(plan: ResearchPlan, collection: ResearchCollectionSnapshot,
                      limits: ResearchEvidenceLimits) throws -> Self {
        try limits.validate()
        guard plan.runID == collection.runID, plan.conversationID == collection.conversationID else {
            throw ValidationError.invalidBinding
        }
        guard collection.sources.count <= limits.sources else { throw ValidationError.invalidCollection }
        let collectionBounds = try ResearchCollectionLimits(maxSources: 64, urlCharacters: 8_192,
            urlBytes: 32_768, textCharacters: 24_000, textBytes: 96_000)
        let queries = Set(plan.queries.map(\.id))
        var keys = Set<String>(), sourceRows: [Source] = [], evidence: [Entry] = [], retainedCharacters = 0
        for (index, item) in collection.sources.enumerated() {
            guard item.id == "source\(index + 1)", keys.insert(item.requestedURLKey).inserted,
                  let requestedURL = URL(string: item.requestedURLKey),
                  try collectionBounds.key(for: requestedURL) == item.requestedURLKey,
                  (try? collectionBounds.key(for: item.source.url)) != nil,
                  !item.queryIDs.isEmpty, Set(item.queryIDs).count == item.queryIDs.count,
                  Set(item.queryIDs).isSubset(of: queries), item.pageFetched || item.source.pageText.isEmpty,
                  [item.source.title, item.source.snippet, item.source.pageText].allSatisfy({
                      $0.count <= collectionBounds.textCharacters && $0.utf8.count <= collectionBounds.textBytes
                  }) else { throw ValidationError.invalidCollection }
            let associations = Set(item.queryIDs)
            let questionIDs = plan.subquestions.filter { !associations.isDisjoint(with: $0.queryIDs) }.map(\.id)
            let pageUseful = !item.source.pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let origin: Origin = item.pageFetched && pageUseful ? .fetchedPage : .searchSnippet
            let selected = origin == .fetchedPage ? item.source.pageText : item.source.snippet
            var iterator = selected.makeIterator(), pending = iterator.next(), offset = 0
            // Chunk whole graphemes; a single oversize grapheme stops the prefix explicitly.
            while pending != nil && evidence.count < limits.entries && retainedCharacters < limits.textCharacters {
                let start = offset
                var characters: [Character] = [], bytes = 0
                while let character = pending, characters.count < limits.segmentCharacters {
                    let size = String(character).utf8.count
                    guard size <= limits.segmentBytes - bytes,
                          characters.count < limits.textCharacters - retainedCharacters else { break }
                    characters.append(character); bytes += size; offset += 1; pending = iterator.next()
                }
                guard !characters.isEmpty else { break }
                let leading = characters.prefix(while: { $0.isWhitespace }).count
                let trimmed = characters.dropFirst(leading).reversed().drop(while: { $0.isWhitespace }).reversed()
                let text = String(trimmed)
                if !text.isEmpty {
                    evidence.append(Entry(id: "evidence\(evidence.count + 1)", sourceID: item.id,
                        characterOffset: start + leading, text: text))
                    retainedCharacters += text.count
                }
            }
            sourceRows.append(Source(id: item.id, requestedURLKey: item.requestedURLKey,
                finalURL: item.source.url.absoluteString, title: item.source.title, queryIDs: item.queryIDs,
                questionIDs: questionIDs, firstObservationQueryID: item.queryIDs[0], firstObservationProvider: item.provider,
                origin: origin, collectedCharacters: selected.count, ledgerTruncated: pending != nil))
        }
        let ledger = Self(version: Self.version, runID: collection.runID, conversationID: collection.conversationID,
                          planContextDigest: try digest(plan), collectionContextDigest: try digest(CollectionContext(collection)),
                          limits: limits, sources: sourceRows, entries: evidence)
        try ledger.validate()
        return ledger
    }

    /// Host byte bound is checked before JSON decoding. Exact projection checks bind transferred
    /// data to the accepted plan, collection and limits, not merely matching UUIDs.
    static func decode(_ data: Data, plan: ResearchPlan, collection: ResearchCollectionSnapshot,
                       limits: ResearchEvidenceLimits) throws -> Self {
        try limits.validate()
        guard data.count <= limits.encodedBytes else { throw ValidationError.oversizedLedger }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard decoded == (try build(plan: plan, collection: collection, limits: limits)) else {
            throw ValidationError.invalidBinding
        }
        return decoded
    }

    private init(version: Int, runID: UUID, conversationID: UUID, planContextDigest: String,
                 collectionContextDigest: String, limits: ResearchEvidenceLimits,
                 sources: [Source], entries: [Entry]) {
        self.version = version; self.runID = runID; self.conversationID = conversationID
        self.planContextDigest = planContextDigest; self.collectionContextDigest = collectionContextDigest
        self.limits = limits; self.sources = sources; self.entries = entries
    }

    private func validate() throws {
        guard version == Self.version else { throw ValidationError.unsupportedVersion }
        try limits.validate()
        guard Self.validDigest(planContextDigest), Self.validDigest(collectionContextDigest),
              sources.count <= limits.sources, entries.count <= limits.entries else { throw ValidationError.invalidStructure }
        let bounds = try ResearchCollectionLimits(maxSources: 64, urlCharacters: 8_192,
            urlBytes: 32_768, textCharacters: 24_000, textBytes: 96_000)
        var keys = Set<String>()
        for (index, source) in sources.enumerated() {
            guard source.id == "source\(index + 1)", keys.insert(source.requestedURLKey).inserted,
                  let requested = URL(string: source.requestedURLKey),
                  (try? bounds.key(for: requested)) == source.requestedURLKey,
                  let final = URL(string: source.finalURL), (try? bounds.key(for: final)) != nil,
                  source.title.count <= bounds.textCharacters, source.title.utf8.count <= bounds.textBytes,
                  !source.queryIDs.isEmpty, source.queryIDs.count <= 128,
                  Set(source.queryIDs).count == source.queryIDs.count,
                  source.queryIDs.allSatisfy({ Self.validID($0, prefix: "query", maximum: 128) }),
                  source.firstObservationQueryID == source.queryIDs.first,
                  !source.questionIDs.isEmpty, source.questionIDs.count <= 32,
                  Set(source.questionIDs).count == source.questionIDs.count,
                  source.questionIDs.allSatisfy({ Self.validID($0, prefix: "question", maximum: 32) }),
                  (0...24_000).contains(source.collectedCharacters) else { throw ValidationError.invalidStructure }
        }
        var lastSource = -1, ends: [String: Int] = [:], characters = 0
        for (index, entry) in entries.enumerated() {
            guard entry.id == "evidence\(index + 1)", let sourceIndex = sources.firstIndex(where: { $0.id == entry.sourceID }),
                  sourceIndex >= lastSource, !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.text.count <= limits.segmentCharacters, entry.text.utf8.count <= limits.segmentBytes,
                  entry.characterOffset >= (ends[entry.sourceID] ?? 0),
                  entry.characterOffset <= sources[sourceIndex].collectedCharacters - entry.text.count else {
                throw ValidationError.invalidStructure
            }
            lastSource = sourceIndex; ends[entry.sourceID] = entry.characterOffset + entry.text.count
            characters += entry.text.count
        }
        guard characters <= limits.textCharacters else { throw ValidationError.invalidStructure }
        guard try JSONEncoder().encode(self).count <= limits.encodedBytes else { throw ValidationError.oversizedLedger }
    }

    private static func validID(_ value: String, prefix: String, maximum: Int) -> Bool {
        guard value.hasPrefix(prefix), let number = Int(value.dropFirst(prefix.count)),
              (1...maximum).contains(number) else { return false }
        return value == "\(prefix)\(number)"
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func digest<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    /// Captures even unselected source text and source UUID; verified bounded before hashing.
    private struct CollectionContext: Encodable {
        struct Row: Encodable {
            let id: String
            let requestedURLKey: String
            let queryIDs: [String]
            let provider: ResearchProvider
            let pageFetched: Bool
            let sourceID: UUID
            let title: String
            let url: String
            let snippet: String
            let pageText: String
        }
        let runID: UUID
        let conversationID: UUID
        let sources: [Row]
        init(_ collection: ResearchCollectionSnapshot) {
            runID = collection.runID; conversationID = collection.conversationID
            sources = collection.sources.map { Row(id: $0.id, requestedURLKey: $0.requestedURLKey,
                queryIDs: $0.queryIDs, provider: $0.provider, pageFetched: $0.pageFetched,
                sourceID: $0.source.id, title: $0.source.title, url: $0.source.url.absoluteString,
                snippet: $0.source.snippet, pageText: $0.source.pageText) }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, runID, conversationID, planContextDigest, collectionContextDigest, limits, sources, entries
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.version else { throw ValidationError.unsupportedVersion }
        runID = try c.decode(UUID.self, forKey: .runID); conversationID = try c.decode(UUID.self, forKey: .conversationID)
        planContextDigest = try c.decode(String.self, forKey: .planContextDigest)
        collectionContextDigest = try c.decode(String.self, forKey: .collectionContextDigest)
        limits = try c.decode(ResearchEvidenceLimits.self, forKey: .limits)
        sources = try c.decode([Source].self, forKey: .sources); entries = try c.decode([Entry].self, forKey: .entries)
        try validate()
    }
}
