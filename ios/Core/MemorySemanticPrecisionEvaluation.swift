#if DEBUG
import Darwin
import Foundation
import SwiftData
import UIKit

struct MemorySemanticPrecisionArtifacts: Sendable {
    let jsonURL: URL
    let markdownURL: URL
    let report: MemorySemanticPrecisionReport
}

struct MemorySemanticPrecisionReport: Codable, Sendable {
    struct Parameters: Codable, Sendable, Equatable {
        let minimumAbsoluteSemantic: Double
        let minimumTopMargin: Double
        let minimumMedianGap: Double
        let minimumRobustZ: Double
        let lexicalThreshold: Double
        let maxSemanticResults: Int
        let maxTotalResults: Int
    }
    struct Metrics: Codable, Sendable {
        let precisionAt1: Double
        let precisionAt3: Double
        let recallAt1: Double
        let recallAt3: Double
        let meanReciprocalRank: Double
        let noResultAccuracy: Double
        let falseRetrievalRate: Double
        let lowOverlapRecall: Double
        let nearTopicNegativeAccuracy: Double
    }
    struct Candidate: Codable, Sendable {
        let memoryID: UUID
        let kind: MemoryKind
        let semanticScore: Double
        let lexicalScore: Double
        let top1Margin: Double
        let medianGap: Double
        let robustZ: Double
        let queryIntent: MemoryQueryIntent
        let kindCompatible: Bool
        let accepted: Bool
        let rejectionReasons: [MemoryCandidateRejectionReason]
    }
    struct QueryResult: Codable, Sendable {
        let id: String
        let category: String
        let query: String
        let expectedMemoryID: UUID?
        let lowOverlap: Bool
        let nearTopicNegative: Bool
        let returnedIDs: [UUID]
        let topCandidates: [Candidate]
    }
    struct Mode: Codable, Sendable {
        let name: String
        let metrics: Metrics
        let queries: [QueryResult]
    }
    struct SetReport: Codable, Sendable {
        let queryCount: Int
        let relevantCount: Int
        let negativeCount: Int
        let modes: [Mode]
    }
    struct Leakage: Codable, Sendable {
        let expired: Int
        let superseded: Int
        let invalidated: Int
        let crossScope: Int
        let staleEmbeddingUse: Int
    }
    let generatedAt: Date
    let device: String
    let systemVersion: String
    let provider: MemoryEmbeddingAvailability
    let development: SetReport
    let frozenParameters: Parameters
    let heldOut: SetReport
    let leakage: Leakage
    let decision: String
}

actor MemorySemanticPrecisionEvaluator {
    func run() async throws -> MemorySemanticPrecisionArtifacts {
        #if targetEnvironment(simulator)
        throw PrecisionEvaluationError.physicalDeviceRequired
        #else
        guard #available(iOS 17.0, *) else { throw PrecisionEvaluationError.iOS17Required }
        let provider = NLContextualMemoryEmbeddingProvider()
        let preparation = await provider.prepareWithDiagnostics(
            for: "用于长期记忆精度评测的中文合成文本。", requestAssetDownload: true
        )
        guard preparation.after.hasAvailableAssets, preparation.after.loaded else {
            throw PrecisionEvaluationError.contextualUnavailable(preparation.requestResult)
        }
        let fixture = PrecisionBenchmark.fixture
        let memoryVectors = try await embedMemories(fixture.memories, provider: provider)
        let developmentPrepared = try await prepare(
            fixture.development, memories: fixture.memories, memoryVectors: memoryVectors, provider: provider
        )
        let parameters = tune(developmentPrepared)
        let development = evaluateSet(developmentPrepared, parameters: parameters)
        // Held-out is deliberately embedded/evaluated only after parameters are frozen.
        let heldOutPrepared = try await prepare(
            fixture.heldOut, memories: fixture.memories, memoryVectors: memoryVectors, provider: provider
        )
        let heldOut = evaluateSet(heldOutPrepared, parameters: parameters)
        let leakage = try await validateLeakage(provider: provider)
        let hybrid = heldOut.modes.first { $0.name == "Production hybrid" }!.metrics
        let decision = hybrid.falseRetrievalRate <= 0.05 && hybrid.noResultAccuracy >= 0.95 &&
            hybrid.precisionAt1 >= 0.95 ? "PASS — semantic retrieval sufficiently precise" : "TUNE"
        let deviceInfo = await Self.deviceInfo()
        let report = MemorySemanticPrecisionReport(
            generatedAt: Date(), device: deviceInfo.0, systemVersion: deviceInfo.1,
            provider: preparation.after, development: development, frozenParameters: parameters,
            heldOut: heldOut, leakage: leakage,
            decision: decision
        )
        return try write(report)
        #endif
    }

    private struct PreparedQuery: Sendable {
        let benchmark: PrecisionQuery
        let rows: [PreparedRow]
        let statistics: MemorySemanticQueryStatistics
    }
    private struct PreparedRow: Sendable {
        let memory: PrecisionMemory
        let semantic: Double
        let lexical: Double
        let entity: Bool
    }

    private func embedMemories(
        _ memories: [PrecisionMemory], provider: NLContextualMemoryEmbeddingProvider
    ) async throws -> [UUID: MemoryEmbeddingVector] {
        var values: [UUID: MemoryEmbeddingVector] = [:]
        for memory in memories { values[memory.id] = try await provider.embedding(for: memory.text) }
        return values
    }

    private func prepare(
        _ queries: [PrecisionQuery], memories: [PrecisionMemory],
        memoryVectors: [UUID: MemoryEmbeddingVector], provider: NLContextualMemoryEmbeddingProvider
    ) async throws -> [PreparedQuery] {
        var output: [PreparedQuery] = []
        for query in queries {
            let vector = try await provider.embedding(for: query.text)
            let rows = memories.compactMap { memory -> PreparedRow? in
                guard let candidate = memoryVectors[memory.id],
                      let cosine = MemoryVectorMath.cosine(vector.values, candidate.values) else { return nil }
                return .init(memory: memory, semantic: max(0, cosine),
                             lexical: MemoryLexicalRelevance.score(query: query.text, candidate: memory.text),
                             entity: MemoryLexicalRelevance.entityMatch(query: query.text, candidate: memory.text))
            }
            guard let statistics = MemorySemanticQueryStatistics.make(scores: rows.map(\.semantic), epsilon: 0.000_001) else {
                throw PrecisionEvaluationError.emptyScores
            }
            output.append(.init(benchmark: query, rows: rows, statistics: statistics))
        }
        return output
    }

    private func tune(_ development: [PreparedQuery]) -> MemorySemanticPrecisionReport.Parameters {
        var best: (MemorySemanticPrecisionReport.Parameters, MemorySemanticPrecisionReport.Metrics)?
        for absolute in [0.72, 0.76, 0.80, 0.84, 0.88, 0.90, 0.92, 0.94] {
            for margin in [0.02, 0.04, 0.06, 0.08, 0.10, 0.12] {
                for gap in [0.06, 0.10, 0.14, 0.18, 0.22] {
                    for robustZ in [2.0, 3.0, 4.0, 5.0, 6.0] {
                        let candidate = MemorySemanticPrecisionReport.Parameters(
                            minimumAbsoluteSemantic: absolute, minimumTopMargin: margin,
                            minimumMedianGap: gap, minimumRobustZ: robustZ,
                            lexicalThreshold: 0.27, maxSemanticResults: 1, maxTotalResults: 2
                        )
                        let metrics = evaluate(development, parameters: candidate, mode: .hybrid).metrics
                        guard isBetter(metrics, than: best?.1) else { continue }
                        best = (candidate, metrics)
                    }
                }
            }
        }
        return best!.0
    }

    private func isBetter(
        _ value: MemorySemanticPrecisionReport.Metrics,
        than current: MemorySemanticPrecisionReport.Metrics?
    ) -> Bool {
        guard let current else { return true }
        let valuePass = value.falseRetrievalRate <= 0.05 && value.noResultAccuracy >= 0.95 && value.precisionAt1 >= 0.95
        let currentPass = current.falseRetrievalRate <= 0.05 && current.noResultAccuracy >= 0.95 && current.precisionAt1 >= 0.95
        if valuePass != currentPass { return valuePass }
        if value.falseRetrievalRate != current.falseRetrievalRate { return value.falseRetrievalRate < current.falseRetrievalRate }
        if value.precisionAt1 != current.precisionAt1 { return value.precisionAt1 > current.precisionAt1 }
        if value.lowOverlapRecall != current.lowOverlapRecall { return value.lowOverlapRecall > current.lowOverlapRecall }
        return value.recallAt1 > current.recallAt1
    }

    private enum Mode { case lexical, rawSemantic, calibrated, hybrid }

    private func evaluateSet(
        _ values: [PreparedQuery], parameters: MemorySemanticPrecisionReport.Parameters
    ) -> MemorySemanticPrecisionReport.SetReport {
        let modes: [(String, Mode)] = [
            ("Lexical only", .lexical), ("Contextual semantic raw", .rawSemantic),
            ("Calibrated semantic", .calibrated), ("Production hybrid", .hybrid)
        ]
        return .init(
            queryCount: values.count, relevantCount: values.filter { $0.benchmark.expected != nil }.count,
            negativeCount: values.filter { $0.benchmark.expected == nil }.count,
            modes: modes.map { evaluate(values, parameters: parameters, mode: $0.1, name: $0.0) }
        )
    }

    private func evaluate(
        _ values: [PreparedQuery], parameters: MemorySemanticPrecisionReport.Parameters,
        mode: Mode, name: String = "Production hybrid"
    ) -> MemorySemanticPrecisionReport.Mode {
        var queryResults: [MemorySemanticPrecisionReport.QueryResult] = []
        for value in values {
            let sorted = value.rows.sorted { $0.semantic > $1.semantic }
            let topID = sorted.first?.memory.id
            let lexical = value.rows.sorted { max($0.lexical, $0.entity ? 1 : 0) > max($1.lexical, $1.entity ? 1 : 0) }
                .first {
                    max($0.lexical, $0.entity ? 1 : 0) >= parameters.lexicalThreshold &&
                    usefulness($0, query: value.benchmark, statistics: value.statistics, parameters: parameters).kindCompatible
                }
            let semantic = sorted.first.flatMap { row -> PreparedRow? in
                let usefulness = usefulness(row, query: value.benchmark, statistics: value.statistics, parameters: parameters)
                return semanticAccepted(row, usefulness: usefulness, statistics: value.statistics, parameters: parameters) ? row : nil
            }
            let returned: [UUID]
            switch mode {
            case .lexical: returned = lexical.map { [$0.memory.id] } ?? []
            case .rawSemantic: returned = sorted.first.map { $0.semantic >= 0.58 ? [$0.memory.id] : [] } ?? []
            case .calibrated: returned = semantic.map { [$0.memory.id] } ?? []
            case .hybrid:
                returned = Array([lexical?.memory.id, semantic?.memory.id].compactMap { $0 }.reduce(into: [UUID]()) {
                    if !$0.contains($1) { $0.append($1) }
                }.prefix(parameters.maxTotalResults))
            }
            let candidates = sorted.prefix(5).map { row -> MemorySemanticPrecisionReport.Candidate in
                let usefulness = usefulness(row, query: value.benchmark, statistics: value.statistics, parameters: parameters)
                var reasons: [MemoryCandidateRejectionReason] = []
                if row.memory.id != topID { reasons.append(.notTopSemanticCandidate) }
                if row.semantic < parameters.minimumAbsoluteSemantic { reasons.append(.belowAbsoluteSemantic) }
                let distribution = value.statistics.top1Top2Margin >= parameters.minimumTopMargin ||
                    value.statistics.top1MedianGap >= parameters.minimumMedianGap || value.statistics.robustZ >= parameters.minimumRobustZ
                if !distribution { reasons += [.insufficientMargin, .insufficientDistributionGap] }
                if !usefulness.kindCompatible { reasons.append(.intentKindIncompatible) }
                let accepted = returned.contains(row.memory.id)
                return .init(memoryID: row.memory.id, kind: row.memory.kind, semanticScore: row.semantic,
                             lexicalScore: row.lexical, top1Margin: value.statistics.top1Top2Margin,
                             medianGap: value.statistics.top1MedianGap, robustZ: value.statistics.robustZ,
                             queryIntent: usefulness.intent, kindCompatible: usefulness.kindCompatible,
                             accepted: accepted, rejectionReasons: accepted ? [] : reasons)
            }
            queryResults.append(.init(
                id: value.benchmark.id, category: value.benchmark.category, query: value.benchmark.text,
                expectedMemoryID: value.benchmark.expected, lowOverlap: value.benchmark.lowOverlap,
                nearTopicNegative: value.benchmark.nearTopicNegative, returnedIDs: returned, topCandidates: candidates
            ))
        }
        return .init(name: name, metrics: metrics(queryResults), queries: queryResults)
    }

    private func usefulness(
        _ row: PreparedRow, query: PrecisionQuery, statistics: MemorySemanticQueryStatistics,
        parameters: MemorySemanticPrecisionReport.Parameters
    ) -> MemoryUsefulnessDecision {
        MemoryUsefulnessGate.evaluate(
            kind: row.memory.kind, query: query.text, statistics: statistics,
            configuration: .init(minimumAbsoluteSemantic: parameters.minimumAbsoluteSemantic,
                                 minimumTopMargin: parameters.minimumTopMargin,
                                 minimumMedianGap: parameters.minimumMedianGap,
                                 minimumRobustZ: parameters.minimumRobustZ)
        )
    }

    private func semanticAccepted(
        _ row: PreparedRow, usefulness: MemoryUsefulnessDecision,
        statistics: MemorySemanticQueryStatistics, parameters: MemorySemanticPrecisionReport.Parameters
    ) -> Bool {
        row.semantic >= parameters.minimumAbsoluteSemantic && usefulness.kindCompatible &&
        (statistics.top1Top2Margin >= parameters.minimumTopMargin ||
         statistics.top1MedianGap >= parameters.minimumMedianGap || statistics.robustZ >= parameters.minimumRobustZ)
    }

    private func metrics(_ values: [MemorySemanticPrecisionReport.QueryResult]) -> MemorySemanticPrecisionReport.Metrics {
        let relevant = values.filter { $0.expectedMemoryID != nil }
        let negatives = values.filter { $0.expectedMemoryID == nil }
        func rank(_ value: MemorySemanticPrecisionReport.QueryResult) -> Int? {
            value.expectedMemoryID.flatMap { id in value.returnedIDs.firstIndex(of: id).map { $0 + 1 } }
        }
        let hits1 = relevant.filter { rank($0) == 1 }.count
        let hits3 = relevant.filter { rank($0).map { $0 <= 3 } ?? false }.count
        let top1Correct = values.filter { value in value.returnedIDs.first == value.expectedMemoryID && value.expectedMemoryID != nil }.count
        let top3Returned = values.reduce(0) { $0 + min(3, $1.returnedIDs.count) }
        let top3Correct = relevant.reduce(0) { $0 + ((rank($1).map { $0 <= 3 } ?? false) ? 1 : 0) }
        let noResultCorrect = negatives.filter { $0.returnedIDs.isEmpty }.count
        let low = relevant.filter(\.lowOverlap)
        let near = negatives.filter(\.nearTopicNegative)
        return .init(
            precisionAt1: values.filter { !$0.returnedIDs.isEmpty }.isEmpty ? 1 : Double(top1Correct) / Double(values.filter { !$0.returnedIDs.isEmpty }.count),
            precisionAt3: top3Returned == 0 ? 1 : Double(top3Correct) / Double(top3Returned),
            recallAt1: Double(hits1) / Double(max(relevant.count, 1)), recallAt3: Double(hits3) / Double(max(relevant.count, 1)),
            meanReciprocalRank: relevant.reduce(0.0) { $0 + (rank($1).map { 1 / Double($0) } ?? 0) } / Double(max(relevant.count, 1)),
            noResultAccuracy: Double(noResultCorrect) / Double(max(negatives.count, 1)),
            falseRetrievalRate: 1 - Double(noResultCorrect) / Double(max(negatives.count, 1)),
            lowOverlapRecall: Double(low.filter { rank($0).map { $0 <= 3 } ?? false }.count) / Double(max(low.count, 1)),
            nearTopicNegativeAccuracy: Double(near.filter { $0.returnedIDs.isEmpty }.count) / Double(max(near.count, 1))
        )
    }

    private func write(_ report: MemorySemanticPrecisionReport) throws -> MemorySemanticPrecisionArtifacts {
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MemorySemanticEvaluation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = "memory-semantic-precision-" + ISO8601DateFormatter().string(from: report.generatedAt).replacingOccurrences(of: ":", with: "-")
        let json = directory.appendingPathComponent(stem + ".json")
        let markdown = directory.appendingPathComponent(stem + ".md")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: json, options: .atomic)
        let test = report.heldOut.modes.first { $0.name == "Production hybrid" }!.metrics
        let text = renderMarkdown(report)
        try text.write(to: markdown, atomically: true, encoding: .utf8)
        return .init(jsonURL: json, markdownURL: markdown, report: report)
    }

    private func renderMarkdown(_ report: MemorySemanticPrecisionReport) -> String {
        let development = report.development.modes.first { $0.name == "Production hybrid" }!
        let heldOut = report.heldOut.modes.first { $0.name == "Production hybrid" }!
        let test = heldOut.metrics
        let falseRetrievals = heldOut.queries.filter { $0.expectedMemoryID == nil && !$0.returnedIDs.isEmpty }
        let falseNegatives = heldOut.queries.filter {
            guard let expected = $0.expectedMemoryID else { return false }
            return !$0.returnedIDs.contains(expected)
        }
        let lowOverlap = heldOut.queries.filter(\.lowOverlap)
        let nearTopic = heldOut.queries.filter(\.nearTopicNegative)

        func format(_ value: Double) -> String { String(format: "%.4f", value) }
        func metricsLine(_ mode: MemorySemanticPrecisionReport.Mode) -> String {
            let value = mode.metrics
            return "| \(mode.name) | \(format(value.precisionAt1)) | \(format(value.precisionAt3)) | \(format(value.recallAt1)) | \(format(value.recallAt3)) | \(format(value.meanReciprocalRank)) | \(format(value.noResultAccuracy)) | \(format(value.falseRetrievalRate)) | \(format(value.lowOverlapRecall)) | \(format(value.nearTopicNegativeAccuracy)) |"
        }
        func queryLines(_ values: [MemorySemanticPrecisionReport.QueryResult], empty: String) -> String {
            guard !values.isEmpty else { return "- \(empty)" }
            return values.map { value in
                let top = value.topCandidates.first
                let scores = top.map {
                    "semantic=\(format($0.semanticScore)), lexical=\(format($0.lexicalScore)), margin=\(format($0.top1Margin)), medianGap=\(format($0.medianGap)), robustZ=\(format($0.robustZ)), intent=\($0.queryIntent.rawValue), compatible=\($0.kindCompatible)"
                } ?? "no candidates"
                return "- `\(value.id)` [\(value.category)] \(value.query) — returned=\(value.returnedIDs.map(\.uuidString)); \(scores)"
            }.joined(separator: "\n")
        }
        func distribution(_ values: [MemorySemanticPrecisionReport.QueryResult]) -> String {
            let rows = values.compactMap { $0.topCandidates.first }
            guard !rows.isEmpty else { return "n/a" }
            func summary(_ keyPath: KeyPath<MemorySemanticPrecisionReport.Candidate, Double>) -> String {
                let values = rows.map { $0[keyPath: keyPath] }.sorted()
                let median = values.count.isMultiple(of: 2)
                    ? (values[values.count / 2 - 1] + values[values.count / 2]) / 2
                    : values[values.count / 2]
                let mean = values.reduce(0, +) / Double(values.count)
                return "min=\(format(values[0])), median=\(format(median)), mean=\(format(mean)), max=\(format(values[values.count - 1]))"
            }
            return "semantic {\(summary(\.semanticScore))}; margin {\(summary(\.top1Margin))}; medianGap {\(summary(\.medianGap))}; robustZ {\(summary(\.robustZ))}"
        }
        func nearTopicGroup(_ prefixes: [String]) -> [MemorySemanticPrecisionReport.QueryResult] {
            nearTopic.filter { value in prefixes.contains { value.category.hasPrefix($0) } }
        }

        return """
        # Step 3.5B Semantic Precision Tuning Report

        ## A. Provider

        NLContextualEmbedding is the only production semantic candidate. If its assets are unavailable, retrieval uses the precision-first lexical/entity path; it does not fall back to NLEmbedding semantic retrieval.

        ## B. Score Distribution Analysis

        Development positives: \(distribution(report.development.modes[1].queries.filter { $0.expectedMemoryID != nil }))

        Development hard negatives: \(distribution(report.development.modes[1].queries.filter { $0.expectedMemoryID == nil }))

        Held-out positives: \(distribution(report.heldOut.modes[1].queries.filter { $0.expectedMemoryID != nil }))

        Held-out hard negatives: \(distribution(report.heldOut.modes[1].queries.filter { $0.expectedMemoryID == nil }))

        ## C. Usefulness Gate

        - preference → recommendation, personalChoice, followUp
        - durableFact → recommendation, personalChoice, personalTroubleshooting, followUp
        - ongoingContext → projectContinuity, personalTroubleshooting, followUp
        - recentState → learningContinuity, followUp, personalChoice
        - event → learningContinuity, followUp; a high-confidence distribution may activate the event-continuity bypass
        - other → followUp

        The same compatibility boundary applies to semantic and lexical/entity candidate paths so an exact artist, movie, or device name cannot inject an unrelated preference into a factual answer.

        ## D. Development Set

        \(report.development.queryCount) queries: \(report.development.relevantCount) relevant and \(report.development.negativeCount) negative. Parameters were selected only from this set by a grid search over absolute score, top margin, median gap, and robust Z, prioritizing false-retrieval rate, then Precision@1, then low-overlap recall.

        | Mode | P@1 | P@3 | R@1 | R@3 | MRR | No-result | False retrieval | Low-overlap | Near-topic negative |
        |---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
        \(report.development.modes.map(metricsLine).joined(separator: "\n"))

        Development production hybrid: false-retrieval=\(format(development.metrics.falseRetrievalRate)), P@1=\(format(development.metrics.precisionAt1)).

        ## E. Frozen Parameters

        - minimumAbsoluteSemantic: \(report.frozenParameters.minimumAbsoluteSemantic)
        - minimumTopMargin: \(report.frozenParameters.minimumTopMargin)
        - minimumMedianGap: \(report.frozenParameters.minimumMedianGap)
        - minimumRobustZ: \(report.frozenParameters.minimumRobustZ)
        - lexicalThreshold: \(report.frozenParameters.lexicalThreshold)
        - maxSemanticResults: \(report.frozenParameters.maxSemanticResults)
        - maxTotalResults: \(report.frozenParameters.maxTotalResults)

        ## F. Held-out Test

        Parameters were frozen before these \(report.heldOut.queryCount) queries were embedded and evaluated.

        | Mode | P@1 | P@3 | R@1 | R@3 | MRR | No-result | False retrieval | Low-overlap | Near-topic negative |
        |---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
        \(report.heldOut.modes.map(metricsLine).joined(separator: "\n"))

        ## G. False Retrievals

        \(queryLines(falseRetrievals, empty: "None"))

        ## H. False Negatives

        \(queryLines(falseNegatives, empty: "None"))

        ## I. Low-overlap Cases

        \(queryLines(lowOverlap, empty: "None"))

        Low-overlap held-out recall: \(format(test.lowOverlapRecall)).

        ## J. Near-topic Negatives

        ### Mathematics across subfields
        \(queryLines(nearTopicGroup(["math-"]), empty: "None"))

        ### Development across platforms/frameworks
        \(queryLines(nearTopicGroup(["dev-"]), empty: "None"))

        ### Music preference vs factual
        \(queryLines(nearTopicGroup(["music-", "audio-"]), empty: "None"))

        ### Movie preference vs factual
        \(queryLines(nearTopicGroup(["movie-"]), empty: "None"))

        ## K. Existing Regression

        Leakage: expired=\(report.leakage.expired), superseded=\(report.leakage.superseded), invalidated=\(report.leakage.invalidated), cross-scope=\(report.leakage.crossScope), stale=\(report.leakage.staleEmbeddingUse).

        ## L. Production Decision

        **\(report.decision)**

        The JSON artifact contains every query's Top 5 memory IDs, kinds, semantic and lexical scores, distribution statistics, intent compatibility, acceptance state, and rejection reasons. It does not contain production user memories.
        """
    }

    private func validateLeakage(
        provider: NLContextualMemoryEmbeddingProvider
    ) async throws -> MemorySemanticPrecisionReport.Leakage {
        let now = Date()
        let fixtures: [(UUID, String, String, MemoryStatus, Date?)] = [
            (UUID(), "expired", "用户正在准备物理考试。", .active, now.addingTimeInterval(-1)),
            (UUID(), "superseded", "用户仍在维护旧安卓项目。", .superseded, nil),
            (UUID(), "invalidated", "用户的电脑是一台台式工作站。", .invalidated, nil),
            (UUID(), "cross", "另一位用户偏好慢节奏电影。", .active, nil),
            (UUID(), "stale", "用户偏好古典绘画。", .active, nil)
        ]
        var records: [MemoryRetrievalRecord] = []
        for value in fixtures {
            let vector = try await provider.embedding(for: value.2)
            let embedding: Data?
            if value.1 == "stale" {
                let descriptor = MemoryEmbeddingDescriptor(
                    provider: "obsolete", modelIdentifier: "obsolete", revision: 0,
                    dimension: 2, modelFamily: "obsolete", language: "zh-Hans", semantic: true
                )
                embedding = try MemoryEmbeddingEnvelope(
                    result: .init(descriptor: descriptor, values: [1, 0]), text: value.2
                ).encoded()
            } else { embedding = try MemoryEmbeddingEnvelope(result: vector, text: value.2).encoded() }
            let scope = value.1 == "cross" ? "other-scope" : MemoryScope.localDefault
            records.append(.init(memory: .init(
                id: value.0, scopeID: scope, kindRawValue: MemoryKind.preference.rawValue,
                canonicalText: value.2, embeddingData: embedding, importance: 0.8, confidence: 0.9,
                statusRawValue: value.3.rawValue, createdAt: now, updatedAt: now,
                lastConfirmedAt: now, lastReinforcedAt: nil, expiresAt: value.4,
                reinforcementCount: 1
            ), sources: []))
        }
        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "PrecisionLeakage", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
        let retriever = MemoryRetriever(
            store: MemoryStore(modelContainer: container),
            semanticResolver: PrecisionContextualResolver(provider: provider)
        )
        var counters = [String: Int]()
        for value in fixtures {
            let evaluated = await retriever.evaluateCandidates(.init(primaryText: value.2), records: records, now: now)
            if let candidate = evaluated.first(where: { $0.memoryID == value.0 }) {
                if value.1 == "stale" { counters[value.1] = candidate.acceptedBySemanticPath ? 1 : 0 }
                else { counters[value.1] = candidate.accepted ? 1 : 0 }
            }
        }
        return .init(expired: counters["expired"] ?? 0, superseded: counters["superseded"] ?? 0,
                     invalidated: counters["invalidated"] ?? 0, crossScope: counters["cross"] ?? 0,
                     staleEmbeddingUse: counters["stale"] ?? 0)
    }

    private static func machineIdentifier() -> String {
        var info = utsname(); uname(&info); var machine = info.machine; let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) { $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) } }
    }

    @MainActor private static func deviceInfo() -> (String, String) {
        (machineIdentifier(), UIDevice.current.systemVersion)
    }
}

private actor PrecisionContextualResolver: MemorySemanticEmbeddingResolving {
    let provider: NLContextualMemoryEmbeddingProvider
    init(provider: NLContextualMemoryEmbeddingProvider) { self.provider = provider }
    func descriptor(for text: String) async -> MemoryEmbeddingDescriptor? {
        guard let value = try? await provider.embedding(for: text) else { return nil }
        return value.descriptor
    }
    func embedding(for text: String) async throws -> MemoryEmbeddingVector {
        try await provider.embedding(for: text)
    }
}

private struct PrecisionMemory: Sendable { let id: UUID; let kind: MemoryKind; let text: String }
private struct PrecisionQuery: Sendable {
    let id: String; let category: String; let text: String; let expected: UUID?; let lowOverlap: Bool; let nearTopicNegative: Bool
}

private enum PrecisionBenchmark {
    static let memories: [PrecisionMemory] = [
        memory(1, .preference, "用户偏好节奏紧凑、智斗多、结局难猜的电影。"),
        memory(2, .event, "用户此前讨论过：特征值相同不足以推出两个矩阵相似。"),
        memory(3, .durableFact, "用户电脑使用 RTX 4070 Laptop GPU。"),
        memory(4, .ongoingContext, "用户正在开发一个调用 DeepSeek API 的 iOS AI 客户端。"),
        memory(5, .preference, "用户不喜欢特别慢热的电影。"),
        memory(6, .recentState, "用户最近在复习线性代数。"),
        memory(7, .preference, "用户重视隐私，不希望把个人笔记上传云端。"),
        memory(8, .durableFact, "用户养了一只名叫糯米的橘猫。"),
        memory(9, .preference, "用户早晨通常喝不加糖的拿铁。"),
        memory(10, .ongoingContext, "用户计划十月去东京旅行并参观秋叶原。"),
        memory(11, .preference, "用户希望数学公式使用 LaTeX 清晰排版。"),
        memory(12, .preference, "用户平时吃素，推荐餐厅时需要素食选项。"),
        memory(13, .durableFact, "用户对花生严重过敏，饮食必须避开花生。"),
        memory(14, .preference, "用户偏好回答先给结论，再提供简洁解释。"),
        memory(15, .durableFact, "用户通常按香港时区安排提醒和定时任务。"),
        memory(16, .ongoingContext, "用户每周三和周六晚上跑步五公里。"),
        memory(17, .preference, "用户常听 YOASOBI 和 Aimer 的音乐。"),
        memory(18, .ongoingContext, "用户购买耳机的预算最多两千元。"),
        memory(19, .preference, "用户偏好使用 SwiftUI 构建原生界面。"),
        memory(20, .ongoingContext, "用户使用 Cloudflare Workers 执行云端定时任务。")
    ]
    static let fixture = (memories: memories, development: makeDevelopment(), heldOut: makeHeldOut())
    static var summary: (development: Int, developmentNegatives: Int, heldOut: Int, heldOutNegatives: Int) {
        (fixture.development.count, fixture.development.filter { $0.expected == nil }.count,
         fixture.heldOut.count, fixture.heldOut.filter { $0.expected == nil }.count)
    }

    private static func memory(_ number: Int, _ kind: MemoryKind, _ text: String) -> PrecisionMemory {
        .init(id: UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", number))!, kind: kind, text: text)
    }
    private static func positive(_ id: String, _ category: String, _ text: String, _ memory: Int, _ low: Bool = true) -> PrecisionQuery {
        .init(id: id, category: category, text: text, expected: memories[memory - 1].id, lowOverlap: low, nearTopicNegative: false)
    }
    private static func negative(_ id: String, _ category: String, _ text: String, near: Bool = true) -> PrecisionQuery {
        .init(id: id, category: category, text: text, expected: nil, lowOverlap: false, nearTopicNegative: near)
    }
    private static func makeDevelopment() -> [PrecisionQuery] {
        let positives: [PrecisionQuery] = [
            positive("d01","movie","给我推荐一部开场就抓人、角色互相算计的反转片。",1), positive("d02","movie","我会喜欢节奏很快的烧脑悬疑片吗？",1),
            positive("d03","math-event","两个方阵谱一致为何仍未必能换基得到彼此？",2), positive("d04","math-event","为什么相同 eigenvalues 不能保证 A 与 B similar？",2),
            positive("d05","device","我的笔记本切换独显后闪黑该怎么排查？",3), positive("d06","device","我这台电脑跑模型时 GPU 驱动崩溃要注意什么？",3),
            positive("d07","project","我这个手机端 AI 助手的跨会话记忆放在哪层？",4), positive("d08","project","当前项目下一步怎样接本地检索？",4),
            positive("d09","movie","推荐不用熬前一小时就进入主线的电影。",5), positive("d10","movie","慢吞吞铺垫的片子适合我吗？",5),
            positive("d11","learning","继续复习时先安排哪门数学课程？",6), positive("d12","learning","我最近学的科目下一章该看什么？",6),
            positive("d13","privacy","按我的偏好，私人资料是否应留在设备端？",7), positive("d14","privacy","给我选一个不上传笔记的知识库方案。",7),
            positive("d15","pet","糯米最近挑食，我该换哪类猫粮？",8,false), positive("d16","pet","我的猫需要做年度体检吗？",8),
            positive("d17","drink","按我的口味推荐一杯晨间奶咖。",9), positive("d18","drink","我会喜欢加糖的焦糖拿铁吗？",9),
            positive("d19","travel","继续规划十月那次日本行程。",10), positive("d20","travel","我之前准备去的电器街附近住哪里？",10),
            positive("d21","format","按我的排版偏好展示这段矩阵推导。",11), positive("d22","format","公式很多时哪种标记语言更适合我？",11),
            positive("d23","diet","按我的饮食习惯推荐一家餐馆。",12), positive("d24","diet","这家只有肉类套餐，适合我吗？",12),
            positive("d25","allergy","这份花生酱甜品我能不能吃？",13,false), positive("d26","allergy","按我的身体条件挑一款不含坚果的零食。",13),
            positive("d27","style","按我习惯先给答案再解释。",14), positive("d28","style","这份回复格式适合我的阅读偏好吗？",14),
            positive("d29","timezone","替我设上午九点提醒，使用我常用时区。",15), positive("d30","timezone","跨区旅行后我的周期任务按哪个地区时间？",15),
            positive("d31","fitness","继续安排我本周的两次夜跑。",16), positive("d32","fitness","按我现有训练习惯调整周末计划。",16),
            positive("d33","music","按我的听歌口味推荐几首日语歌。",17), positive("d34","music","我会喜欢偏抒情的日本女声吗？",17),
            positive("d35","shopping","这副 2300 元耳机超出我的购买范围吗？",18,false), positive("d36","shopping","按我能接受的价格推荐降噪耳机。",18),
            positive("d37","ui","当前项目界面继续采用我偏好的原生框架吗？",19), positive("d38","ui","按我的技术偏好选 UIKit 还是声明式方案？",19),
            positive("d39","cloud","我这个任务系统离线后如何继续准点运行？",20), positive("d40","cloud","继续完善现有边缘调度服务。",20)
        ]
        let negatives: [PrecisionQuery] = [
            negative("dn01","math-calculus","拉格朗日中值定理如何证明？"), negative("dn02","math-probability","中心极限定理的条件是什么？"),
            negative("dn03","math-complex","复变函数的留数怎么计算？"), negative("dn04","math-discrete","图论中的欧拉回路是什么？"),
            negative("dn05","dev-android","Android 申请相机权限需要哪些配置？"), negative("dn06","dev-react","React 的 useEffect 为什么会执行两次？"),
            negative("dn07","dev-swift","Swift actor 的隔离规则是什么？"), negative("dn08","device-fact","OLED 为什么会烧屏？"),
            negative("dn09","movie-fact","《盗梦空间》是哪一年上映的？"), negative("dn10","movie-fact","这部电影的导演是谁？"),
            negative("dn11","movie-fact","今年全球票房冠军是哪一部？"), negative("dn12","movie-history","法国新浪潮有哪些代表导演？"),
            negative("dn13","music-fact","Aimer 最新专辑发布日期是什么时候？"), negative("dn14","music-fact","YOASOBI 的主唱叫什么？"),
            negative("dn15","music-fact","这首歌获得过哪些奖项？"), negative("dn16","audio-fact","主动降噪耳机的工作原理是什么？"),
            negative("dn17","travel-fact","东京今天会下雨吗？"), negative("dn18","travel-fact","秋叶原车站有几条线路？"),
            negative("dn19","pet-fact","猫科动物如何捕猎？"), negative("dn20","pet-fact","橘猫的毛色由什么基因决定？"),
            negative("dn21","coffee-fact","浅烘与深烘咖啡豆有什么区别？"), negative("dn22","coffee-fact","拿铁最早起源于哪个国家？"),
            negative("dn23","food-fact","花生属于坚果还是豆科？"), negative("dn24","food-fact","素食主义有哪些流派？"),
            negative("dn25","timezone-fact","UTC 是如何定义的？"), negative("dn26","timezone-fact","香港与东京相差几个小时？"),
            negative("dn27","running-fact","半程马拉松标准距离是多少？"), negative("dn28","running-fact","跑步为什么会产生乳酸？"),
            negative("dn29","cloud-fact","Cloudflare CDN 如何缓存静态资源？"), negative("dn30","cloud-fact","Workers 的免费额度是多少？"),
            negative("dn31","ios-fact","iOS 的应用沙盒包含哪些目录？"), negative("dn32","ios-fact","SwiftUI 的 View 协议如何工作？"),
            negative("dn33","privacy-fact","端到端加密的原理是什么？"), negative("dn34","privacy-fact","GDPR 适用于哪些地区？"),
            negative("dn35","writing","写一首关于海边的短诗。",near: false), negative("dn36","weather","明天北京天气怎么样？",near: false),
            negative("dn37","history","莎士比亚出生在哪里？",near: false), negative("dn38","science","黑洞霍金辐射是什么？",near: false),
            negative("dn39","finance","美元兑人民币汇率是多少？",near: false), negative("dn40","translation","把这句话翻译成法语。",near: false)
        ]
        return positives + negatives
    }
    private static func makeHeldOut() -> [PrecisionQuery] {
        let positives: [PrecisionQuery] = [
            positive("t01","movie","想挑一部剧情推进利落、人物斗心眼的片子。",1), positive("t02","math-event","矩阵拥有相同谱为何仍可能不相似？",2),
            positive("t03","device","我自己的笔记本启用高性能显卡时短暂黑屏。",3), positive("t04","project","继续做这个掌上智能助手，记忆检索应如何编排？",4),
            positive("t05","movie","我适合看需要很久才展开剧情的作品吗？",5), positive("t06","learning","接着安排我近期数学复习的内容。",6),
            positive("t07","privacy","哪种方案更符合我对个人文档的隐私要求？",7), positive("t08","pet","给我家那只猫选个日常护理计划。",8),
            positive("t09","drink","根据我的习惯挑一杯早上喝的咖啡。",9), positive("t10","travel","接着规划秋季那次日本动漫街区之行。",10),
            positive("t11","format","按我喜欢的方式排版下面的积分公式。",11), positive("t12","diet","这间烤肉店符合我的饮食选择吗？",12),
            positive("t13","allergy","这包点心标注含花生碎，我可以尝吗？",13,false), positive("t14","style","用我习惯的结构回答，别先铺垫。",14),
            positive("t15","timezone","我常用地区的早上八点创建周期提醒。",15), positive("t16","fitness","延续我一周两晚的锻炼安排。",16),
            positive("t17","music","照我的音乐喜好推荐通勤歌单。",17), positive("t18","shopping","按我原先能承受的价位挑头戴式耳机。",18),
            positive("t19","ui","这个苹果端项目的界面技术继续按我偏好选择。",19), positive("t20","cloud","让现有周期任务在手机断网时也照常触发。",20),
            positive("t21","math-event","已知两个矩阵特征根完全相同，为何结论仍不成立？",2), positive("t22","project","这个 App 下一阶段怎样做跨会话状态？",4),
            positive("t23","movie","给我找一部不用耐心熬开头的悬疑片。",5), positive("t24","privacy","本地资料增强回答时按我的要求怎么部署？",7),
            positive("t25","device","我的移动显卡工作时偶尔闪一下屏幕。",3)
        ]
        let negatives: [PrecisionQuery] = [
            negative("tn01","math-calculus","泰勒公式的余项有哪些形式？"), negative("tn02","math-probability","大数定律与中心极限定理有何区别？"),
            negative("tn03","math-complex","解析函数满足柯西黎曼条件吗？"), negative("tn04","math-discrete","哈密顿图的判定为什么困难？"),
            negative("tn05","dev-android","Kotlin 协程如何切换线程？"), negative("tn06","dev-web","Vue 的响应式系统怎样追踪依赖？"),
            negative("tn07","dev-swift","Swift 的值类型与引用类型有什么区别？"), negative("tn08","device-fact","Mini LED 和 OLED 有什么区别？"),
            negative("tn09","movie-fact","《教父》的摄影指导是谁？"), negative("tn10","movie-fact","某部影片在北美首周票房多少？"),
            negative("tn11","movie-fact","今年戛纳金棕榈由谁获得？"), negative("tn12","music-fact","Aimer 第一张专辑叫什么？"),
            negative("tn13","music-fact","YOASOBI 什么时候成立？"), negative("tn14","music-fact","这首单曲在榜单最高第几名？"),
            negative("tn15","audio-fact","蓝牙耳机的编码格式有哪些？"), negative("tn16","travel-fact","东京地铁末班车通常几点？"),
            negative("tn17","pet-fact","猫的胡须有什么功能？"), negative("tn18","coffee-fact","浓缩咖啡的标准萃取比例是多少？"),
            negative("tn19","food-fact","植物蛋白如何做到营养互补？"), negative("tn20","timezone-fact","夏令时为什么会产生？"),
            negative("tn21","running-fact","跑鞋的碳板有什么作用？"), negative("tn22","cloud-fact","CDN 回源机制是怎样的？"),
            negative("tn23","ios-fact","App 生命周期有哪些状态？"), negative("tn24","privacy-fact","非对称加密如何交换密钥？"),
            negative("tn25","general","太阳系有多少颗行星？",near: false)
        ]
        return positives + negatives
    }
}

enum MemorySemanticPrecisionTestHooks {
    static var benchmarkSummary: (development: Int, developmentNegatives: Int, heldOut: Int, heldOutNegatives: Int) {
        PrecisionBenchmark.summary
    }
}

private enum PrecisionEvaluationError: LocalizedError {
    case physicalDeviceRequired, iOS17Required, contextualUnavailable(String), emptyScores
    var errorDescription: String? {
        switch self {
        case .physicalDeviceRequired: "必须在真实 iPhone 上运行 Step 3.5B。"
        case .iOS17Required: "NLContextualEmbedding 需要 iOS 17 或更高版本。"
        case .contextualUnavailable(let detail): "Contextual assets 不可用：\(detail)"
        case .emptyScores: "未生成 semantic score。"
        }
    }
}
#endif
