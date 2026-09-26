import Foundation

struct MemoryRetrievalInput: Sendable, Equatable {
    let primaryText: String
    let contextText: String?
    let scopeID: String
    let excludingConversationID: UUID?

    init(
        primaryText: String,
        contextText: String? = nil,
        scopeID: String = MemoryScope.localDefault,
        excludingConversationID: UUID? = nil
    ) {
        self.primaryText = primaryText
        self.contextText = contextText
        self.scopeID = scopeID
        self.excludingConversationID = excludingConversationID
    }

    var combinedText: String {
        [contextText, primaryText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct MemoryRetrievalResult: Codable, Sendable, Equatable, Identifiable {
    var id: UUID { memoryID }
    let memoryID: UUID
    let kind: MemoryKind
    let canonicalText: String
    let semanticAvailable: Bool
    let semanticScore: Double
    let lexicalScore: Double
    let entityMatch: Bool
    let relevanceScore: Double
    let recencyScore: Double
    let importanceScore: Double
    let reinforcementScore: Double
    let finalScore: Double
    let rank: Int
    let lastConfirmedAt: Date
    let expiresAt: Date?
}

struct MemoryRetrievalRecord: Sendable, Equatable {
    let memory: MemoryItemSnapshot
    let sources: [MemorySourceSnapshot]
}

struct MemoryRetrievalConfiguration: Sendable, Equatable {
    var lexicalGate = 0.27
    var semanticConfidence = MemorySemanticConfidenceConfiguration()
    var semanticGate: Double {
        get { semanticConfidence.minimumAbsoluteSemantic }
        set { semanticConfidence.minimumAbsoluteSemantic = newValue }
    }
    var semanticRelevanceWeight = 0.78
    var lexicalRelevanceWeight = 0.17
    var entityRelevanceWeight = 0.05
    var relevanceWeight = 0.80
    var recencyWeight = 0.08
    var importanceWeight = 0.07
    var reinforcementWeight = 0.05
    var reinforcementK = 0.55
    var maximumResults = 2
    var maximumSemanticResults = 1
    var maximumLexicalResults = 1

    func halfLifeDays(for kind: MemoryKind) -> Double {
        switch kind {
        case .recentState: 7
        case .ongoingContext: 30
        case .event: 180
        case .preference: 365
        case .durableFact: 730
        case .other: 90
        }
    }
}

protocol MemorySemanticEmbeddingResolving: Sendable {
    func descriptor(for text: String) async -> MemoryEmbeddingDescriptor?
    func embedding(for text: String) async throws -> MemoryEmbeddingVector
}

actor MemorySemanticEmbeddingResolver: MemorySemanticEmbeddingResolving {
    @available(iOS 17.0, *) private lazy var contextual = NLContextualMemoryEmbeddingProvider()

    func descriptor(for text: String) async -> MemoryEmbeddingDescriptor? {
        if #available(iOS 17.0, *) {
            let contextualState = await contextual.prepare(for: text, requestAssetDownload: false)
            if contextualState.hasAvailableAssets, contextualState.loaded {
                return Self.descriptor(from: contextualState)
            }
        }
        return nil
    }

    func embedding(for text: String) async throws -> MemoryEmbeddingVector {
        if #available(iOS 17.0, *) {
            let state = await contextual.prepare(for: text, requestAssetDownload: false)
            if state.hasAvailableAssets, state.loaded { return try await contextual.embedding(for: text) }
        }
        throw MemoryEmbeddingError.providerUnavailable(MemoryEmbeddingText.language(for: text).rawValue)
    }

    private static func descriptor(from state: MemoryEmbeddingAvailability) -> MemoryEmbeddingDescriptor? {
        guard state.semantic, state.loaded,
              let modelIdentifier = state.modelIdentifier,
              let revision = state.revision,
              let dimension = state.dimension
        else { return nil }
        return .init(
            provider: state.provider,
            modelIdentifier: modelIdentifier,
            revision: revision,
            dimension: dimension,
            modelFamily: state.modelFamily,
            language: state.language,
            semantic: true
        )
    }
}

actor MemoryRetriever {
    private let store: MemoryStore
    private let semanticResolver: (any MemorySemanticEmbeddingResolving)?
    private let configuration: MemoryRetrievalConfiguration

    init(
        store: MemoryStore,
        semanticResolver: (any MemorySemanticEmbeddingResolving)? = MemorySemanticEmbeddingResolver(),
        configuration: MemoryRetrievalConfiguration = .init()
    ) {
        self.store = store
        self.semanticResolver = semanticResolver
        self.configuration = configuration
    }

    func search(_ input: MemoryRetrievalInput, now: Date = Date()) async throws -> [MemoryRetrievalResult] {
        let records = try await store.retrievalRecords(scopeID: input.scopeID)
        return await rank(input, records: records, now: now)
    }

    func rank(
        _ input: MemoryRetrievalInput,
        records: [MemoryRetrievalRecord],
        now: Date = Date()
    ) async -> [MemoryRetrievalResult] {
        let evaluated = await evaluateCandidates(input, records: records, now: now)
        let acceptedIDs = Set(evaluated.filter(\.accepted).map(\.memoryID))
        guard !acceptedIDs.isEmpty else { return [] }
        let query = input.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryVector = try? await semanticResolver?.embedding(for: query)
        var staged: [(MemoryItemSnapshot, Bool, Double, Double, Bool, Double, Double, Double, Double, Double)] = []
        for record in records where acceptedIDs.contains(record.memory.id) {
            let item = record.memory
            let canonical = item.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let lexical = MemoryLexicalRelevance.score(query: query, candidate: canonical)
            let entity = MemoryLexicalRelevance.entityMatch(query: query, candidate: canonical)
            var semanticAvailable = false
            var semantic = 0.0
            if let queryVector,
               let data = item.embeddingData,
               let envelope = try? MemoryEmbeddingEnvelope.decode(data),
               envelope.isCurrent(for: canonical, descriptor: queryVector.descriptor),
               let cosine = MemoryVectorMath.cosine(queryVector.values, envelope.vector) {
                semanticAvailable = true
                semantic = max(0, cosine)
            }
            let relevance: Double
            if semanticAvailable {
                relevance = clamp(
                    configuration.semanticRelevanceWeight * semantic +
                    configuration.lexicalRelevanceWeight * lexical +
                    configuration.entityRelevanceWeight * (entity ? 1 : 0)
                )
            } else {
                let lexicalWeight = configuration.lexicalRelevanceWeight + configuration.semanticRelevanceWeight
                relevance = clamp(lexicalWeight * lexical + configuration.entityRelevanceWeight * (entity ? 1 : 0))
            }
            let ageDays = max(0, now.timeIntervalSince(item.lastConfirmedAt) / 86_400)
            let recency = exp(-log(2) * ageDays / configuration.halfLifeDays(for: item.kind))
            let reinforcement = 1 - exp(-configuration.reinforcementK * Double(max(0, item.reinforcementCount)))
            let importance = MemoryScore.clamped(item.importance)
            let final = clamp(
                configuration.relevanceWeight * relevance +
                configuration.recencyWeight * recency +
                configuration.importanceWeight * importance +
                configuration.reinforcementWeight * reinforcement
            )
            staged.append((item, semanticAvailable, semantic, lexical, entity, relevance, recency, importance, reinforcement, final))
        }

        return staged.sorted {
            if $0.9 != $1.9 { return $0.9 > $1.9 }
            if $0.5 != $1.5 { return $0.5 > $1.5 }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.prefix(max(0, configuration.maximumResults)).enumerated().map { offset, value in
            .init(
                memoryID: value.0.id, kind: value.0.kind, canonicalText: value.0.canonicalText,
                semanticAvailable: value.1, semanticScore: value.2, lexicalScore: value.3,
                entityMatch: value.4, relevanceScore: value.5, recencyScore: value.6,
                importanceScore: value.7, reinforcementScore: value.8, finalScore: value.9,
                rank: offset + 1, lastConfirmedAt: value.0.lastConfirmedAt, expiresAt: value.0.expiresAt
            )
        }
    }

    func evaluateCandidates(
        _ input: MemoryRetrievalInput,
        records: [MemoryRetrievalRecord],
        now: Date = Date()
    ) async -> [MemoryCandidateEvaluation] {
        let query = input.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !input.scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let queryVector = try? await semanticResolver?.embedding(for: query)
        struct Working {
            let item: MemoryItemSnapshot
            let lexical: Double
            let entity: Bool
            let semantic: Double?
            var eligibilityRejection: MemoryCandidateRejectionReason?
        }
        var working: [Working] = []
        for record in records {
            let item = record.memory
            let canonical = item.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let rejection: MemoryCandidateRejectionReason?
            if item.scopeID != input.scopeID { rejection = .wrongScope }
            else if item.status == .superseded { rejection = .superseded }
            else if item.status == .invalidated { rejection = .invalidated }
            else if item.expiresAt.map({ $0 <= now }) ?? false { rejection = .expired }
            else if canonical.isEmpty { rejection = .emptyText }
            else if let excluded = input.excludingConversationID,
                    !record.sources.isEmpty,
                    record.sources.allSatisfy({ $0.sourceConversationID == excluded }) { rejection = .currentConversationOnly }
            else { rejection = nil }
            let lexical = MemoryLexicalRelevance.score(query: query, candidate: canonical)
            let entity = MemoryLexicalRelevance.entityMatch(query: query, candidate: canonical)
            var semantic: Double?
            if rejection == nil, let queryVector, let data = item.embeddingData,
               let envelope = try? MemoryEmbeddingEnvelope.decode(data),
               envelope.isCurrent(for: canonical, descriptor: queryVector.descriptor),
               let cosine = MemoryVectorMath.cosine(queryVector.values, envelope.vector) {
                semantic = max(0, cosine)
            }
            working.append(.init(item: item, lexical: lexical, entity: entity, semantic: semantic, eligibilityRejection: rejection))
        }
        let eligibleSemantic = working.compactMap { $0.eligibilityRejection == nil ? $0.semantic : nil }
        let statistics = MemorySemanticQueryStatistics.make(
            scores: eligibleSemantic, epsilon: configuration.semanticConfidence.epsilon
        )
        let semanticTopID = working.filter { $0.eligibilityRejection == nil && $0.semantic != nil }.max {
            ($0.semantic ?? 0) < ($1.semantic ?? 0)
        }?.item.id
        let lexicalIDs = Set(working.filter {
            guard $0.eligibilityRejection == nil,
                  max($0.lexical, $0.entity ? 1 : 0) >= configuration.lexicalGate
            else { return false }
            return MemoryUsefulnessGate.evaluate(
                kind: $0.item.kind,
                query: query,
                statistics: statistics,
                configuration: configuration.semanticConfidence
            ).kindCompatible
        }.sorted {
            max($0.lexical, $0.entity ? 1 : 0) > max($1.lexical, $1.entity ? 1 : 0)
        }.prefix(max(0, configuration.maximumLexicalResults)).map { $0.item.id })

        var evaluations: [MemoryCandidateEvaluation] = []
        for value in working {
            let usefulness = MemoryUsefulnessGate.evaluate(
                kind: value.item.kind, query: query, statistics: statistics,
                configuration: configuration.semanticConfidence
            )
            var reasons: [MemoryCandidateRejectionReason] = []
            if let rejection = value.eligibilityRejection { reasons.append(rejection) }
            let lexicalAccepted = value.eligibilityRejection == nil && lexicalIDs.contains(value.item.id)
            var semanticAccepted = false
            if value.eligibilityRejection == nil, let semantic = value.semantic, let statistics {
                if value.item.id != semanticTopID { reasons.append(.notTopSemanticCandidate) }
                else {
                    if semantic < configuration.semanticConfidence.minimumAbsoluteSemantic { reasons.append(.belowAbsoluteSemantic) }
                    let distributionPassed = statistics.top1Top2Margin >= configuration.semanticConfidence.minimumTopMargin ||
                        statistics.top1MedianGap >= configuration.semanticConfidence.minimumMedianGap ||
                        statistics.robustZ >= configuration.semanticConfidence.minimumRobustZ
                    if !distributionPassed {
                        reasons.append(.insufficientMargin)
                        reasons.append(.insufficientDistributionGap)
                    }
                    if !usefulness.kindCompatible { reasons.append(.intentKindIncompatible) }
                    semanticAccepted = reasons.isEmpty
                }
            } else if value.eligibilityRejection == nil {
                reasons.append(.staleEmbedding)
            }
            if value.eligibilityRejection == nil,
               max(value.lexical, value.entity ? 1 : 0) >= configuration.lexicalGate,
               !usefulness.kindCompatible {
                reasons.append(.intentKindIncompatible)
            }
            if !lexicalAccepted && value.eligibilityRejection == nil && !semanticAccepted &&
                max(value.lexical, value.entity ? 1 : 0) < configuration.lexicalGate {
                reasons.append(.belowLexicalGate)
            }
            evaluations.append(.init(
                memoryID: value.item.id, kind: value.item.kind, semanticScore: value.semantic,
                lexicalScore: value.lexical, entityMatch: value.entity, semanticStatistics: statistics,
                queryIntent: usefulness.intent, kindCompatible: usefulness.kindCompatible,
                acceptedByLexicalPath: lexicalAccepted, acceptedBySemanticPath: semanticAccepted,
                accepted: lexicalAccepted || semanticAccepted,
                rejectionReasons: lexicalAccepted || semanticAccepted ? [] : Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
            ))
        }
        let accepted = evaluations.filter(\.accepted).sorted {
            let left = max($0.entityMatch ? 1 : $0.lexicalScore, $0.semanticScore ?? 0)
            let right = max($1.entityMatch ? 1 : $1.lexicalScore, $1.semanticScore ?? 0)
            return left > right
        }
        let allowed = Set(accepted.prefix(max(0, configuration.maximumResults)).map(\.memoryID))
        return evaluations.map { value in
            guard value.accepted, !allowed.contains(value.memoryID) else { return value }
            return .init(
                memoryID: value.memoryID, kind: value.kind, semanticScore: value.semanticScore,
                lexicalScore: value.lexicalScore, entityMatch: value.entityMatch,
                semanticStatistics: value.semanticStatistics, queryIntent: value.queryIntent,
                kindCompatible: value.kindCompatible, acceptedByLexicalPath: value.acceptedByLexicalPath,
                acceptedBySemanticPath: value.acceptedBySemanticPath, accepted: false,
                rejectionReasons: [.resultLimit]
            )
        }
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

enum MemoryLexicalRelevance {
    private static let stopWords: Set<String> = [
        "用户", "我", "我的", "什么", "哪个", "哪些", "怎么", "如何", "是否", "最近", "现在", "一个", "这个", "那个",
        "the", "a", "an", "is", "are", "what", "which", "how", "my", "do", "does", "for", "to"
    ]
    private static let conceptGroups: [[String]] = [
        ["早上", "早晨", "清晨", "morning"], ["喝", "饮用", "drink", "咖啡", "拿铁"],
        ["宠物", "猫", "橘猫", "pet", "cat"], ["旅行", "旅游", "出行", "trip", "travel"],
        ["喜欢", "偏好", "倾向", "prefer", "preference"], ["不上传", "本地", "隐私", "privacy", "local"],
        ["公式", "方程", "数学", "equation", "latex"], ["手机", "iphone", "phone", "设备"],
        ["提醒", "时区", "timezone", "schedule"], ["素食", "吃素", "vegetarian"],
        ["过敏", "避开", "不能吃", "allergy"], ["框架", "swiftui", "ui"],
        ["后端", "worker", "workers", "backend", "typescript"], ["跑步", "running", "run"],
        ["音乐", "歌手", "歌曲", "music", "song"], ["预算", "最多", "价格", "budget"]
    ]

    static func score(query: String, candidate: String) -> Double {
        let lhs = features(query)
        let rhs = features(candidate)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        let dice = 2 * Double(intersection) / Double(lhs.count + rhs.count)
        let concepts = conceptTokens(query).intersection(conceptTokens(candidate))
        let conceptScore = min(1, Double(concepts.count) / 2)
        let left = MemoryEmbeddingText.normalized(query)
        let right = MemoryEmbeddingText.normalized(candidate)
        let containment = left.count >= 2 && right.count >= 2 && (left.contains(right) || right.contains(left)) ? 1.0 : 0
        return min(1, 0.68 * dice + 0.24 * conceptScore + 0.08 * containment)
    }

    static func entityMatch(query: String, candidate: String) -> Bool {
        !entities(query).intersection(entities(candidate)).isEmpty
    }

    private static func features(_ text: String) -> Set<String> {
        let normalized = MemoryEmbeddingText.normalized(text)
        var result = Set(normalized.split { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "#" }
            .map(String.init).filter { $0.count > 1 && !stopWords.contains($0) })
        let cjk = Array(normalized.filter { $0.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } })
        if cjk.count > 1 {
            result.formUnion((0..<(cjk.count - 1)).map { String([cjk[$0], cjk[$0 + 1]]) }.filter { !stopWords.contains($0) })
        }
        result.formUnion(conceptTokens(text))
        return result
    }

    private static func conceptTokens(_ text: String) -> Set<String> {
        let normalized = MemoryEmbeddingText.normalized(text)
        return Set(conceptGroups.enumerated().compactMap { index, terms in
            terms.contains(where: normalized.contains) ? "concept:\(index)" : nil
        })
    }

    private static func entities(_ text: String) -> Set<String> {
        let generic: Set<String> = ["ios", "api", "ui", "app", "用户", "memory"]
        return Set(text.split { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "#" && $0 != "!" }
            .map { String($0).lowercased() }
            .filter { token in token.count >= 2 && !generic.contains(token) && token.contains(where: { $0.isASCII }) })
    }
}

struct MemoryEmbeddingBackfillReport: Sendable, Equatable {
    let examined: Int
    let written: Int
    let skippedCurrent: Int
    let unavailable: Int
    let failed: Int
}

actor MemoryEmbeddingBackfillService {
    private let store: MemoryStore
    private let resolver: any MemorySemanticEmbeddingResolving

    init(store: MemoryStore, resolver: any MemorySemanticEmbeddingResolving = MemorySemanticEmbeddingResolver()) {
        self.store = store
        self.resolver = resolver
    }

    func backfill(scopeID: String = MemoryScope.localDefault, now: Date = Date()) async -> MemoryEmbeddingBackfillReport {
        guard let records = try? await store.retrievalRecords(scopeID: scopeID) else {
            return .init(examined: 0, written: 0, skippedCurrent: 0, unavailable: 0, failed: 1)
        }
        var written = 0
        var skipped = 0
        var unavailable = 0
        var failed = 0
        let eligible = records.map(\.memory).filter {
            $0.status == .active && ($0.expiresAt.map { $0 > now } ?? true) && !$0.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for item in eligible {
            guard let descriptor = await resolver.descriptor(for: item.canonicalText) else {
                unavailable += 1
                continue
            }
            if let data = item.embeddingData,
               let envelope = try? MemoryEmbeddingEnvelope.decode(data),
               envelope.isCurrent(for: item.canonicalText, descriptor: descriptor) {
                skipped += 1
                continue
            }
            do {
                let vector = try await resolver.embedding(for: item.canonicalText)
                let data = try MemoryEmbeddingEnvelope(result: vector, text: item.canonicalText).encoded()
                let didWrite = try await store.setEmbeddingData(
                    data, memoryID: item.id, scopeID: scopeID,
                    expectedCanonicalTextHash: MemoryEmbeddingText.hash(item.canonicalText)
                )
                if didWrite { written += 1 } else { failed += 1 }
            } catch { failed += 1 }
        }
        return .init(examined: eligible.count, written: written, skippedCurrent: skipped, unavailable: unavailable, failed: failed)
    }
}
