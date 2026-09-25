#if DEBUG
import Darwin
import Foundation
import NaturalLanguage
import SwiftData
import UIKit

enum MemorySemanticEvaluationDecision: String, Codable, Sendable {
    case selectNLEmbedding = "SELECT NLEmbedding"
    case selectNLContextualEmbedding = "SELECT NLContextualEmbedding"
    case noReliableProvider = "NO LOCAL SEMANTIC PROVIDER RELIABLE ENOUGH"
}

struct MemorySemanticEvaluationArtifacts: Sendable {
    let jsonURL: URL
    let markdownURL: URL
    let report: MemorySemanticEvaluationReport
}

struct MemorySemanticEvaluationReport: Codable, Sendable {
    struct Device: Codable, Sendable {
        let model: String
        let systemVersion: String
        let architecture: String
        let locale: String
        let preferredLanguages: [String]
        let physicalDevice: Bool
        let previousRunAt: Date?
    }

    struct Provider: Codable, Sendable {
        let name: String
        let availability: [MemoryEmbeddingAvailability]
        let assetPreparation: [MemoryContextualPreparationReport]
        let initializationMilliseconds: Int
        let firstEmbeddingMilliseconds: Double?
        let subsequentLatencyP50Milliseconds: Double?
        let subsequentLatencyP95Milliseconds: Double?
        let residentMemoryDeltaBytes: Int64?
        let stability: Stability
        let error: String?
    }

    struct Stability: Codable, Sendable {
        let repeatedRequestCount: Int
        let repeatedFailures: Int
        let concurrentRequestCount: Int
        let concurrentFailures: Int
        let dimensionMismatchCount: Int
        let metadataMismatchCount: Int
        let minimumRepeatedCosine: Double?
    }

    struct Metrics: Codable, Sendable {
        let recallAt1: Double
        let recallAt3: Double
        let recallAt5: Double
        let precisionAt3: Double
        let meanReciprocalRank: Double
        let noResultAccuracy: Double
        let falseRetrievalRate: Double
        let lowOverlapRecallAt3: Double
    }

    struct Mode: Codable, Sendable {
        let name: String
        let provider: String?
        let metrics: Metrics
        let outcomes: [Outcome]
        let leakage: Leakage
    }

    struct Outcome: Codable, Sendable {
        let queryID: String
        let category: String
        let query: String
        let expectedMemory: String?
        let retrievedMemoryIDs: [UUID]
        let expectedRank: Int?
        let lexicalScore: Double?
        let semanticScore: Double?
        let mustNotRetrieveViolations: [UUID]
    }

    struct Leakage: Codable, Sendable {
        let sensitive: Int
        let expired: Int
        let superseded: Int
        let invalidated: Int
        let crossScope: Int
        let staleEmbeddingUse: Int

        var allZero: Bool {
            sensitive == 0 && expired == 0 && superseded == 0 && invalidated == 0 &&
            crossScope == 0 && staleEmbeddingUse == 0
        }
    }

    let generatedAt: Date
    let device: Device
    let benchmarkQueryCount: Int
    let lowOverlapQueryCount: Int
    let providers: [Provider]
    let modes: [Mode]
    let decision: MemorySemanticEvaluationDecision
    let finalGate: String
    let notes: [String]
}

actor MemorySemanticPhysicalDeviceEvaluator {
    private let configuration = MemoryRetrievalConfiguration()
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    func run(requestContextualAssets: Bool = true) async throws -> MemorySemanticEvaluationArtifacts {
        let defaults = UserDefaults.standard
        let previousRunAt = defaults.object(forKey: "memorySemanticEvaluation.lastRunAt") as? Date
        let device = await Self.deviceReport(previousRunAt: previousRunAt)
        guard device.physicalDevice else { throw EvaluationError.physicalDeviceRequired }

        let fixture = try MemorySemanticEvaluationBenchmark.fixture(now: now)
        let lexical = await evaluateLexical(fixture: fixture)

        let sentence = NLSentenceMemoryEmbeddingProvider()
        let sentenceRun = await evaluateProvider(
            name: "NLEmbedding", provider: sentence, preparations: [], fixture: fixture
        )

        var contextualPreparations: [MemoryContextualPreparationReport] = []
        var contextualRun: ProviderRun?
        if #available(iOS 17.0, *) {
            let contextual = NLContextualMemoryEmbeddingProvider()
            contextualPreparations.append(await contextual.prepareWithDiagnostics(
                for: "这是用于检测中文语义模型可用性的合成文本。",
                requestAssetDownload: requestContextualAssets
            ))
            contextualPreparations.append(await contextual.prepareWithDiagnostics(
                for: "Synthetic English text used only to inspect local model availability.",
                requestAssetDownload: requestContextualAssets
            ))
            contextualRun = await evaluateProvider(
                name: "NLContextualEmbedding", provider: contextual,
                preparations: contextualPreparations, fixture: fixture
            )
        }

        let runs = [sentenceRun, contextualRun].compactMap { $0 }
        let decision = selectProvider(runs)
        let selectedRun = runs.first { run in
            (decision == .selectNLEmbedding && run.report.name == "NLEmbedding") ||
            (decision == .selectNLContextualEmbedding && run.report.name == "NLContextualEmbedding")
        }
        let selectedHybrid = selectedRun?.hybrid
        let targetPassed = selectedHybrid.map(Self.passesTargets) ?? false
        let finalGate = targetPassed ? "PASS" : (runs.contains(where: { $0.semantic != nil }) ? "TUNE" : "FAIL")
        let report = MemorySemanticEvaluationReport(
            generatedAt: Date(), device: device,
            benchmarkQueryCount: fixture.queries.count,
            lowOverlapQueryCount: fixture.queries.filter(\.lowOverlap).count,
            providers: runs.map(\.report),
            modes: [lexical] + runs.flatMap { [$0.semantic, $0.hybrid].compactMap { $0 } },
            decision: decision, finalGate: finalGate,
            notes: [
                "All benchmark records are synthetic and remain in memory; the real MemoryStore is neither read nor written.",
                "NLContextualEmbedding uses arithmetic mean pooling over all returned subword vectors followed by L2 normalization.",
                "A second cold-launch comparison requires force-quitting the app, relaunching it, and running this evaluator again; previousRunAt records the prior completed run.",
                "Sensitive-memory prevention is owned by the extraction validator. The retrieval regression fixture represents a rejected sensitive item as invalidated and verifies zero return leakage."
            ]
        )
        let artifacts = try Self.write(report)
        defaults.set(report.generatedAt, forKey: "memorySemanticEvaluation.lastRunAt")
        return artifacts
    }

    private func evaluateLexical(fixture: EvaluationFixture) async -> MemorySemanticEvaluationReport.Mode {
        let retriever = MemoryRetriever(store: fixture.unusedStore, semanticResolver: nil, configuration: configuration)
        var outputs: [QueryOutput] = []
        for query in fixture.queries {
            let results = await retriever.rank(query.input, records: fixture.records, now: now)
            outputs.append(.init(query: query, results: results))
        }
        return score(name: "Lexical/entity only", provider: nil, outputs: outputs, forbidden: fixture.forbidden)
    }

    private struct ProviderRun {
        let report: MemorySemanticEvaluationReport.Provider
        let semantic: MemorySemanticEvaluationReport.Mode?
        let hybrid: MemorySemanticEvaluationReport.Mode?
    }

    private func evaluateProvider(
        name: String,
        provider: any MemoryEmbeddingProvider,
        preparations: [MemoryContextualPreparationReport],
        fixture: EvaluationFixture
    ) async -> ProviderRun {
        let availabilityStarted = Date()
        let chineseAvailability = await provider.availability(for: "中文语义可用性检测")
        let englishAvailability = await provider.availability(for: "English semantic availability check")
        let availability = [chineseAvailability, englishAvailability]
        let initializationMs = Int(Date().timeIntervalSince(availabilityStarted) * 1_000)
        let memoryBefore = Self.residentMemoryBytes()
        let probe = "用户偏好节奏紧凑、充满博弈而且结局难猜的电影。"
        let firstStarted = Date()
        let firstResult: Result<MemoryEmbeddingVector, Error>
        do { firstResult = .success(try await provider.embedding(for: probe)) }
        catch { firstResult = .failure(error) }
        let firstMs = Date().timeIntervalSince(firstStarted) * 1_000

        guard case .success = firstResult else {
            let error = firstResult.failureDescription
            return .init(report: .init(
                name: name, availability: availability, assetPreparation: preparations,
                initializationMilliseconds: initializationMs, firstEmbeddingMilliseconds: nil,
                subsequentLatencyP50Milliseconds: nil, subsequentLatencyP95Milliseconds: nil,
                residentMemoryDeltaBytes: Self.memoryDelta(before: memoryBefore, after: Self.residentMemoryBytes()),
                stability: .init(repeatedRequestCount: 0, repeatedFailures: 1, concurrentRequestCount: 0,
                                 concurrentFailures: 0, dimensionMismatchCount: 0, metadataMismatchCount: 0,
                                 minimumRepeatedCosine: nil),
                error: error
            ), semantic: nil, hybrid: nil)
        }

        let stability = await stability(provider: provider, text: probe)
        var latencies: [Double] = []
        for _ in 0..<20 {
            let started = Date()
            _ = try? await provider.embedding(for: probe)
            latencies.append(Date().timeIntervalSince(started) * 1_000)
        }

        var records = fixture.records
        var embeddingErrors: [String] = []
        for index in records.indices where !fixture.forbidden.staleIDs.contains(records[index].memory.id) {
            do {
                let vector = try await provider.embedding(for: records[index].memory.canonicalText)
                records[index] = Self.recordReplacingEmbedding(records[index], vector: vector)
            } catch { embeddingErrors.append("memory \(records[index].memory.id): \(error)") }
        }

        let resolver = EvaluationProviderResolver(provider: provider)
        let retriever = MemoryRetriever(store: fixture.unusedStore, semanticResolver: resolver, configuration: configuration)
        var semanticOutputs: [QueryOutput] = []
        var hybridOutputs: [QueryOutput] = []
        for query in fixture.queries {
            let queryVector = try? await provider.embedding(for: query.input.combinedText)
            semanticOutputs.append(.init(
                query: query,
                results: semanticRank(query: query, queryVector: queryVector, records: records)
            ))
            hybridOutputs.append(.init(
                query: query,
                results: await retriever.rank(query.input, records: records, now: now)
            ))
        }
        let semantic = score(name: "Semantic only", provider: name, outputs: semanticOutputs, forbidden: fixture.forbidden)
        let hybrid = score(name: "Production hybrid", provider: name, outputs: hybridOutputs, forbidden: fixture.forbidden)
        let providerReport = MemorySemanticEvaluationReport.Provider(
            name: name, availability: availability, assetPreparation: preparations,
            initializationMilliseconds: initializationMs, firstEmbeddingMilliseconds: firstMs,
            subsequentLatencyP50Milliseconds: Self.percentile(latencies, 0.50),
            subsequentLatencyP95Milliseconds: Self.percentile(latencies, 0.95),
            residentMemoryDeltaBytes: Self.memoryDelta(before: memoryBefore, after: Self.residentMemoryBytes()),
            stability: stability,
            error: embeddingErrors.isEmpty ? nil : embeddingErrors.joined(separator: " | ")
        )
        return .init(report: providerReport, semantic: semantic, hybrid: hybrid)
    }

    private func semanticRank(
        query: EvaluationQuery,
        queryVector: MemoryEmbeddingVector?,
        records: [MemoryRetrievalRecord]
    ) -> [MemoryRetrievalResult] {
        guard let queryVector else { return [] }
        var staged: [(MemoryItemSnapshot, Double)] = []
        for record in records {
            let item = record.memory
            guard item.scopeID == query.input.scopeID,
                  item.status == .active,
                  item.expiresAt.map({ $0 > now }) ?? true,
                  !item.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = item.embeddingData,
                  let envelope = try? MemoryEmbeddingEnvelope.decode(data),
                  envelope.isCurrent(for: item.canonicalText, descriptor: queryVector.descriptor),
                  let cosine = MemoryVectorMath.cosine(queryVector.values, envelope.vector)
            else { continue }
            let semantic = max(0, cosine)
            guard semantic >= configuration.semanticGate else { continue }
            staged.append((item, semantic))
        }
        return staged.sorted { $0.1 == $1.1 ? $0.0.id.uuidString < $1.0.id.uuidString : $0.1 > $1.1 }
            .prefix(configuration.maximumResults).enumerated().map { offset, value in
                .init(memoryID: value.0.id, kind: value.0.kind, canonicalText: value.0.canonicalText,
                      semanticAvailable: true, semanticScore: value.1, lexicalScore: 0, entityMatch: false,
                      relevanceScore: value.1, recencyScore: 0, importanceScore: value.0.importance,
                      reinforcementScore: 0, finalScore: value.1, rank: offset + 1,
                      lastConfirmedAt: value.0.lastConfirmedAt, expiresAt: value.0.expiresAt)
            }
    }

    private struct QueryOutput {
        let query: EvaluationQuery
        let results: [MemoryRetrievalResult]
    }

    private func score(
        name: String,
        provider: String?,
        outputs: [QueryOutput],
        forbidden: ForbiddenIDs
    ) -> MemorySemanticEvaluationReport.Mode {
        let relevant = outputs.filter { $0.query.mustRetrieve != nil }
        let noResult = outputs.filter { $0.query.mustRetrieve == nil }
        var hits1 = 0, hits3 = 0, hits5 = 0, correctTop3 = 0, returnedTop3 = 0
        var reciprocal = 0.0, noResultCorrect = 0, falseRetrieval = 0, lowHits3 = 0
        var allResults: [MemoryRetrievalResult] = []
        let outcomes = outputs.map { output -> MemorySemanticEvaluationReport.Outcome in
            let top3 = Array(output.results.prefix(3))
            returnedTop3 += top3.count
            allResults.append(contentsOf: output.results)
            var expectedRank: Int?
            if let expected = output.query.mustRetrieve {
                expectedRank = output.results.firstIndex { $0.memoryID == expected }.map { $0 + 1 }
                hits1 += expectedRank == 1 ? 1 : 0
                hits3 += (expectedRank.map { $0 <= 3 } ?? false) ? 1 : 0
                hits5 += (expectedRank.map { $0 <= 5 } ?? false) ? 1 : 0
                correctTop3 += top3.filter { $0.memoryID == expected }.count
                if let expectedRank { reciprocal += 1 / Double(expectedRank) }
                if output.query.lowOverlap, expectedRank.map({ $0 <= 3 }) ?? false { lowHits3 += 1 }
            } else if output.results.isEmpty { noResultCorrect += 1 }
            else { falseRetrieval += 1 }
            let target = output.results.first { $0.memoryID == output.query.mustRetrieve }
            let expectedText = output.query.mustRetrieve.flatMap { id in
                MemorySemanticEvaluationBenchmark.memoryTextByID[id]
            }
            return .init(
                queryID: output.query.id, category: output.query.category, query: output.query.input.combinedText,
                expectedMemory: expectedText,
                retrievedMemoryIDs: output.results.map(\.memoryID), expectedRank: expectedRank,
                lexicalScore: expectedText.map {
                    MemoryLexicalRelevance.score(query: output.query.input.combinedText, candidate: $0)
                },
                semanticScore: target?.semanticScore,
                mustNotRetrieveViolations: output.results.map(\.memoryID).filter(output.query.mustNotRetrieve.contains)
            )
        }
        let lowCount = relevant.filter { $0.query.lowOverlap }.count
        let metrics = MemorySemanticEvaluationReport.Metrics(
            recallAt1: Double(hits1) / Double(max(relevant.count, 1)),
            recallAt3: Double(hits3) / Double(max(relevant.count, 1)),
            recallAt5: Double(hits5) / Double(max(relevant.count, 1)),
            precisionAt3: returnedTop3 == 0 ? 1 : Double(correctTop3) / Double(returnedTop3),
            meanReciprocalRank: reciprocal / Double(max(relevant.count, 1)),
            noResultAccuracy: Double(noResultCorrect) / Double(max(noResult.count, 1)),
            falseRetrievalRate: Double(falseRetrieval) / Double(max(noResult.count, 1)),
            lowOverlapRecallAt3: Double(lowHits3) / Double(max(lowCount, 1))
        )
        let returned = Set(allResults.map(\.memoryID))
        let leakage = MemorySemanticEvaluationReport.Leakage(
            sensitive: returned.intersection(forbidden.sensitiveIDs).count,
            expired: returned.intersection(forbidden.expiredIDs).count,
            superseded: returned.intersection(forbidden.supersededIDs).count,
            invalidated: returned.intersection(forbidden.invalidatedIDs).count,
            crossScope: returned.intersection(forbidden.crossScopeIDs).count,
            staleEmbeddingUse: allResults.filter { forbidden.staleIDs.contains($0.memoryID) && $0.semanticAvailable }.count
        )
        return .init(name: name, provider: provider, metrics: metrics, outcomes: outcomes, leakage: leakage)
    }

    private func stability(provider: any MemoryEmbeddingProvider, text: String) async -> MemorySemanticEvaluationReport.Stability {
        var repeated: [MemoryEmbeddingVector] = []
        var repeatedFailures = 0
        for _ in 0..<10 {
            do { repeated.append(try await provider.embedding(for: text)) }
            catch { repeatedFailures += 1 }
        }
        let concurrent = await withTaskGroup(of: Result<MemoryEmbeddingVector, Error>.self) { group in
            for _ in 0..<10 { group.addTask { do { return .success(try await provider.embedding(for: text)) } catch { return .failure(error) } } }
            var values: [Result<MemoryEmbeddingVector, Error>] = []
            for await value in group { values.append(value) }
            return values
        }
        let concurrentValues = concurrent.compactMap { try? $0.get() }
        let all = repeated + concurrentValues
        let reference = all.first
        let dimensionMismatch = reference.map { first in all.filter { $0.values.count != first.values.count }.count } ?? 0
        let metadataMismatch = reference.map { first in all.filter { $0.descriptor != first.descriptor }.count } ?? 0
        let cosines = reference.map { first in repeated.compactMap { MemoryVectorMath.cosine(first.values, $0.values) } } ?? []
        return .init(
            repeatedRequestCount: 10, repeatedFailures: repeatedFailures,
            concurrentRequestCount: 10, concurrentFailures: 10 - concurrentValues.count,
            dimensionMismatchCount: dimensionMismatch, metadataMismatchCount: metadataMismatch,
            minimumRepeatedCosine: cosines.min()
        )
    }

    private func selectProvider(_ runs: [ProviderRun]) -> MemorySemanticEvaluationDecision {
        let candidates = runs.compactMap { run -> (ProviderRun, MemorySemanticEvaluationReport.Mode)? in
            guard let hybrid = run.hybrid,
                  hybrid.leakage.allZero,
                  hybrid.metrics.precisionAt3 >= 0.95,
                  hybrid.metrics.noResultAccuracy >= 0.95,
                  hybrid.metrics.lowOverlapRecallAt3 >= 0.85,
                  run.report.stability.repeatedFailures == 0,
                  run.report.stability.concurrentFailures == 0,
                  run.report.stability.dimensionMismatchCount == 0,
                  run.report.stability.metadataMismatchCount == 0
            else { return nil }
            return (run, hybrid)
        }.sorted {
            if $0.1.metrics.precisionAt3 != $1.1.metrics.precisionAt3 { return $0.1.metrics.precisionAt3 > $1.1.metrics.precisionAt3 }
            if $0.1.metrics.lowOverlapRecallAt3 != $1.1.metrics.lowOverlapRecallAt3 { return $0.1.metrics.lowOverlapRecallAt3 > $1.1.metrics.lowOverlapRecallAt3 }
            return ($0.0.report.subsequentLatencyP50Milliseconds ?? .infinity) < ($1.0.report.subsequentLatencyP50Milliseconds ?? .infinity)
        }
        guard let best = candidates.first?.0 else { return .noReliableProvider }
        return best.report.name == "NLEmbedding" ? .selectNLEmbedding : .selectNLContextualEmbedding
    }

    private static func passesTargets(_ mode: MemorySemanticEvaluationReport.Mode) -> Bool {
        mode.leakage.allZero && mode.metrics.lowOverlapRecallAt3 >= 0.85 &&
        mode.metrics.precisionAt3 >= 0.95 && mode.metrics.noResultAccuracy >= 0.95
    }

    private static func recordReplacingEmbedding(
        _ record: MemoryRetrievalRecord,
        vector: MemoryEmbeddingVector
    ) -> MemoryRetrievalRecord {
        let item = record.memory
        let data = try? MemoryEmbeddingEnvelope(result: vector, text: item.canonicalText).encoded()
        return .init(memory: .init(
            id: item.id, scopeID: item.scopeID, kindRawValue: item.kindRawValue,
            canonicalText: item.canonicalText, embeddingData: data, importance: item.importance,
            confidence: item.confidence, statusRawValue: item.statusRawValue, createdAt: item.createdAt,
            updatedAt: item.updatedAt, lastConfirmedAt: item.lastConfirmedAt,
            lastReinforcedAt: item.lastReinforcedAt, expiresAt: item.expiresAt,
            reinforcementCount: item.reinforcementCount
        ), sources: record.sources)
    }

    @MainActor
    private static func deviceReport(previousRunAt: Date?) -> MemorySemanticEvaluationReport.Device {
        #if targetEnvironment(simulator)
        let physical = false
        #else
        let physical = true
        #endif
        return .init(
            model: machineIdentifier(), systemVersion: UIDevice.current.systemVersion,
            architecture: architectureIdentifier(), locale: Locale.current.identifier,
            preferredLanguages: Locale.preferredLanguages,
            physicalDevice: physical && UIDevice.current.userInterfaceIdiom == .phone,
            previousRunAt: previousRunAt
        )
    }

    private static func architectureIdentifier() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        var machine = systemInfo.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private static func residentMemoryBytes() -> Int64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : nil
    }

    private static func memoryDelta(before: Int64?, after: Int64?) -> Int64? {
        guard let before, let after else { return nil }
        return max(0, after - before)
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[Int((Double(sorted.count - 1) * percentile).rounded())]
    }

    private static func write(_ report: MemorySemanticEvaluationReport) throws -> MemorySemanticEvaluationArtifacts {
        let directory = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("MemorySemanticEvaluation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let stem = "memory-semantic-\(formatter.string(from: report.generatedAt).replacingOccurrences(of: ":", with: "-"))"
        let jsonURL = directory.appendingPathComponent(stem + ".json")
        let markdownURL = directory.appendingPathComponent(stem + ".md")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: jsonURL, options: .atomic)
        try markdown(report).write(to: markdownURL, atomically: true, encoding: .utf8)
        return .init(jsonURL: jsonURL, markdownURL: markdownURL, report: report)
    }

    private static func markdown(_ report: MemorySemanticEvaluationReport) -> String {
        func f(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "n/a" }
        let providerRows = report.providers.map { provider in
            "| \(provider.name) | \(f(provider.firstEmbeddingMilliseconds)) | \(f(provider.subsequentLatencyP50Milliseconds)) | \(f(provider.subsequentLatencyP95Milliseconds)) | \(provider.residentMemoryDeltaBytes.map(String.init) ?? "n/a") | \(provider.error ?? "none") |"
        }.joined(separator: "\n")
        let modeRows = report.modes.map { mode in
            let m = mode.metrics
            return "| \(mode.name) | \(mode.provider ?? "fallback") | \(f(m.recallAt1)) | \(f(m.recallAt3)) | \(f(m.recallAt5)) | \(f(m.precisionAt3)) | \(f(m.meanReciprocalRank)) | \(f(m.noResultAccuracy)) | \(f(m.falseRetrievalRate)) | \(f(m.lowOverlapRecallAt3)) |"
        }.joined(separator: "\n")
        let hardNegatives = report.modes.flatMap { mode in
            mode.outcomes.filter { $0.expectedMemory == nil && !$0.retrievedMemoryIDs.isEmpty }.map {
                "- \(mode.name) / \($0.queryID): \($0.query) → \($0.retrievedMemoryIDs.count) result(s)"
            }
        }.joined(separator: "\n")
        let assets = report.providers.flatMap { provider in
            provider.assetPreparation.map { prep in
                "- \(provider.name) \(prep.before.language): before=\(prep.before.hasAvailableAssets), request=\(prep.requestResult), after=\(prep.after.hasAvailableAssets), duration=\(prep.durationMilliseconds)ms"
            }
        }.joined(separator: "\n")
        let leakRows = report.modes.map { mode in
            let l = mode.leakage
            return "- \(mode.name) \(mode.provider ?? "fallback"): sensitive=\(l.sensitive), expired=\(l.expired), superseded=\(l.superseded), invalidated=\(l.invalidated), cross-scope=\(l.crossScope), stale-use=\(l.staleEmbeddingUse)"
        }.joined(separator: "\n")
        let lexicalMode = report.modes.first { $0.name == "Lexical/entity only" }
        let semanticMode = report.modes.first {
            $0.name == "Semantic only" &&
            ((report.decision == .selectNLEmbedding && $0.provider == "NLEmbedding") ||
             (report.decision == .selectNLContextualEmbedding && $0.provider == "NLContextualEmbedding"))
        } ?? report.modes.first { $0.name == "Semantic only" }
        let hybridMode = report.modes.first {
            $0.name == "Production hybrid" && $0.provider == semanticMode?.provider
        }
        let comparisonRows = (lexicalMode?.outcomes ?? []).filter { $0.expectedMemory != nil }.prefix(12).map { lexical in
            let semantic = semanticMode?.outcomes.first { $0.queryID == lexical.queryID }
            let hybrid = hybridMode?.outcomes.first { $0.queryID == lexical.queryID }
            return "| \(lexical.queryID) | \(lexical.query.replacingOccurrences(of: "|", with: "\\|")) | \(f(lexical.lexicalScore)) | \(f(semantic?.semanticScore)) | \(hybrid?.expectedRank.map(String.init) ?? "miss") |"
        }.joined(separator: "\n")
        return """
        # Step 3.5 Physical Device Semantic Evaluation Report

        ## A. Device

        Device: \(report.device.model)<br>
        iOS: \(report.device.systemVersion)<br>
        Architecture: \(report.device.architecture)<br>
        Locale: \(report.device.locale)<br>
        Languages: \(report.device.preferredLanguages.joined(separator: ", "))<br>
        Physical device: \(report.device.physicalDevice)<br>
        Previous completed run: \(report.device.previousRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")

        ## B–D. Provider Availability, Assets, and Metadata

        \(assets.isEmpty ? "No contextual asset request was recorded." : assets)

        | Provider | First embedding ms | Warm P50 ms | Warm P95 ms | Resident delta bytes | Error |
        |---|---:|---:|---:|---:|---|
        \(providerRows)

        ## E–F. Benchmark and Low-overlap Results

        Queries: \(report.benchmarkQueryCount); low-overlap: \(report.lowOverlapQueryCount).

        | Mode | Provider | R@1 | R@3 | R@5 | P@3 | MRR | No-result | False retrieval | Low-overlap R@3 |
        |---|---|---:|---:|---:|---:|---:|---:|---:|---:|
        \(modeRows)

        ### Semantic contribution examples

        | Query | Low-overlap expression | Lexical | Semantic | Hybrid target rank |
        |---|---|---:|---:|---:|
        \(comparisonRows)

        ## G. Hard Negatives

        \(hardNegatives.isEmpty ? "No hard-negative false retrievals." : hardNegatives)

        ## H. Provider Comparison and Decision

        **\(report.decision.rawValue)**

        Precision, no-result accuracy, and leakage gates are evaluated before recall and latency.

        ## I–J. Latency and Stability

        See provider table above. Each available provider was embedded 10 times sequentially and 10 times concurrently; detailed counters are in the JSON report.

        ## K. Existing Step 3 Regression

        \(leakRows)

        ## L. Production Decision

        **\(report.decision.rawValue)**

        ## M. Final Gate

        **Step 3 semantic validation: \(report.finalGate)**
        """
    }
}

private actor EvaluationProviderResolver: MemorySemanticEmbeddingResolving {
    let provider: any MemoryEmbeddingProvider
    init(provider: any MemoryEmbeddingProvider) { self.provider = provider }
    func descriptor(for text: String) async -> MemoryEmbeddingDescriptor? {
        guard let vector = try? await provider.embedding(for: text) else { return nil }
        return vector.descriptor
    }
    func embedding(for text: String) async throws -> MemoryEmbeddingVector {
        try await provider.embedding(for: text)
    }
}

private struct EvaluationQuery: Sendable {
    let id: String
    let category: String
    let input: MemoryRetrievalInput
    let mustRetrieve: UUID?
    let mustNotRetrieve: Set<UUID>
    let lowOverlap: Bool
}

private struct ForbiddenIDs: Sendable {
    let sensitiveIDs: Set<UUID>
    let expiredIDs: Set<UUID>
    let supersededIDs: Set<UUID>
    let invalidatedIDs: Set<UUID>
    let crossScopeIDs: Set<UUID>
    let staleIDs: Set<UUID>
}

private struct EvaluationFixture {
    let records: [MemoryRetrievalRecord]
    let queries: [EvaluationQuery]
    let forbidden: ForbiddenIDs
    let unusedStore: MemoryStore
}

private enum MemorySemanticEvaluationBenchmark {
    private static let ids: [String: UUID] = [
        "movie": UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        "matrix": UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        "gpu": UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
        "project": UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
        "slow": UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
        "linear": UUID(uuidString: "10000000-0000-0000-0000-000000000006")!,
        "privacy": UUID(uuidString: "10000000-0000-0000-0000-000000000007")!,
        "cat": UUID(uuidString: "10000000-0000-0000-0000-000000000008")!,
        "coffee": UUID(uuidString: "10000000-0000-0000-0000-000000000009")!,
        "tokyo": UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
        "latex": UUID(uuidString: "10000000-0000-0000-0000-000000000011")!,
        "vegetarian": UUID(uuidString: "10000000-0000-0000-0000-000000000012")!,
        "allergy": UUID(uuidString: "10000000-0000-0000-0000-000000000013")!,
        "concise": UUID(uuidString: "10000000-0000-0000-0000-000000000014")!,
        "timezone": UUID(uuidString: "10000000-0000-0000-0000-000000000015")!,
        "running": UUID(uuidString: "10000000-0000-0000-0000-000000000016")!,
        "music": UUID(uuidString: "10000000-0000-0000-0000-000000000017")!,
        "budget": UUID(uuidString: "10000000-0000-0000-0000-000000000018")!,
        "swiftui": UUID(uuidString: "10000000-0000-0000-0000-000000000019")!,
        "backend": UUID(uuidString: "10000000-0000-0000-0000-000000000020")!
    ]

    static let memoryTextByID: [UUID: String] = Dictionary(uniqueKeysWithValues: memories.map { (ids[$0.0]!, $0.2) })

    static var summary: (queries: Int, relevant: Int, noResult: Int, lowOverlap: Int) {
        (
            queries.count,
            queries.filter { $0.mustRetrieve != nil }.count,
            queries.filter { $0.mustRetrieve == nil }.count,
            queries.filter { $0.lowOverlap }.count
        )
    }

    private static let memories: [(String, MemoryKind, String)] = [
        ("movie", .preference, "用户偏好节奏紧凑、智斗多、结局难猜的电影。"),
        ("matrix", .event, "用户此前讨论过：特征值相同不足以推出两个矩阵相似。"),
        ("gpu", .durableFact, "用户电脑使用 RTX 4070 Laptop GPU。"),
        ("project", .ongoingContext, "用户正在开发一个调用 DeepSeek API 的 iOS AI 客户端。"),
        ("slow", .preference, "用户不喜欢特别慢热的电影。"),
        ("linear", .recentState, "用户最近在复习线性代数。"),
        ("privacy", .preference, "用户重视隐私，不希望把个人笔记上传到云端。"),
        ("cat", .durableFact, "用户养了一只名叫糯米的橘猫。"),
        ("coffee", .preference, "用户早晨通常喝不加糖的拿铁。"),
        ("tokyo", .ongoingContext, "用户计划十月去东京旅行并参观秋叶原。"),
        ("latex", .preference, "用户希望数学公式使用 LaTeX 清晰排版。"),
        ("vegetarian", .preference, "用户平时吃素，推荐餐厅时需要素食选项。"),
        ("allergy", .durableFact, "用户对花生严重过敏，饮食必须避开花生。"),
        ("concise", .preference, "用户偏好回答先给结论，再提供简洁解释。"),
        ("timezone", .durableFact, "用户通常按香港时区安排提醒和定时任务。"),
        ("running", .ongoingContext, "用户每周三和周六晚上跑步五公里。"),
        ("music", .preference, "用户常听 YOASOBI 和 Aimer 的音乐。"),
        ("budget", .ongoingContext, "用户购买耳机的预算最多两千元。"),
        ("swiftui", .preference, "用户偏好使用 SwiftUI 构建原生界面。"),
        ("backend", .ongoingContext, "用户使用 Cloudflare Workers 执行云端定时任务。")
    ]

    static func fixture(now: Date) throws -> EvaluationFixture {
        var records = memories.enumerated().map { offset, value in
            record(id: ids[value.0]!, kind: value.1, text: value.2, scope: MemoryScope.localDefault,
                   status: .active, now: now.addingTimeInterval(-Double(offset) * 86_400))
        }
        let expired = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let superseded = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let invalidated = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        let otherScope = UUID(uuidString: "20000000-0000-0000-0000-000000000004")!
        let stale = UUID(uuidString: "20000000-0000-0000-0000-000000000005")!
        let sensitive = UUID(uuidString: "20000000-0000-0000-0000-000000000006")!
        records += [
            record(id: expired, kind: .recentState, text: "用户正在准备明天的物理考试。", scope: MemoryScope.localDefault, status: .active, now: now, expiresAt: now.addingTimeInterval(-1)),
            record(id: superseded, kind: .ongoingContext, text: "用户还在维护已经结束的旧安卓项目。", scope: MemoryScope.localDefault, status: .superseded, now: now),
            record(id: invalidated, kind: .durableFact, text: "用户的主力电脑是台式工作站。", scope: MemoryScope.localDefault, status: .invalidated, now: now),
            record(id: otherScope, kind: .preference, text: "另一位用户偏好慢节奏文艺电影。", scope: "other-user", status: .active, now: now),
            record(id: stale, kind: .preference, text: "用户偏好观看快节奏的悬疑电影。", scope: MemoryScope.localDefault, status: .active, now: now, embeddingData: staleEnvelope(text: "用户偏好观看快节奏的悬疑电影。")),
            record(id: sensitive, kind: .other, text: "合成测试 API Key sk-redacted 必须被拒绝。", scope: MemoryScope.localDefault, status: .invalidated, now: now)
        ]
        let forbidden = ForbiddenIDs(
            sensitiveIDs: [sensitive], expiredIDs: [expired], supersededIDs: [superseded],
            invalidatedIDs: [invalidated, sensitive], crossScopeIDs: [otherScope], staleIDs: [stale]
        )
        let store = MemoryStore(modelContainer: try MemoryEvaluationContainer.make())
        return .init(records: records, queries: queries, forbidden: forbidden, unusedStore: store)
    }

    private static var queries: [EvaluationQuery] {
        let q: [(String, String, String, String?, Bool)] = [
            ("r01", "synonym", "给我推荐点全程不拖、人物互相算计，而且最后还有反转的片子。", "movie", true),
            ("r02", "concept", "两个方阵的谱完全一样，为什么还是不能保证存在 P⁻¹AP=B？", "matrix", true),
            ("r03", "device", "我笔记本独显工作时屏幕偶尔瞬间黑一下。", "gpu", true),
            ("r04", "project", "我现在这个手机端 AI 助手该怎么处理跨会话上下文？", "project", true),
            ("r05", "movie", "有没有那种不用熬前一个小时，很快就进入主线的？", "slow", true),
            ("r06", "privacy", "资料都只留在设备上，不经过服务器的方案怎么做？", "privacy", true),
            ("r07", "pet", "给糯米挑猫粮时应该注意什么？", "cat", false),
            ("r08", "drink", "晨起想换一种不甜的奶咖，有什么建议？", "coffee", true),
            ("r09", "travel", "秋天去日本电器街那趟行程怎么排？", "tokyo", true),
            ("r10", "format", "推导过程里的式子怎样显示得更清楚？", "latex", true),
            ("r11", "diet", "找饭店时帮我过滤掉只有荤菜的地方。", "vegetarian", true),
            ("r12", "safety", "买零食配料表里哪种坚果必须替我排除？", "allergy", true),
            ("r13", "style", "先说答案，理由不要铺垫太长。", "concise", true),
            ("r14", "schedule", "上午九点的提醒按我常用地区时间触发。", "timezone", true),
            ("r15", "fitness", "周末前那两次夜跑分别安排在哪天？", "running", true),
            ("r16", "music", "推荐一些和《夜に駆ける》演唱者风格接近的歌。", "music", true),
            ("r17", "shopping", "看中的降噪耳机卖 2300，超出我能接受的范围吗？", "budget", true),
            ("r18", "ui", "苹果平台的声明式原生 UI 继续沿用合适吗？", "swiftui", true),
            ("r19", "cloud", "手机关机后周期任务仍要准时执行，现有边缘服务怎么接？", "backend", true),
            ("r20", "matrix", "A 和 B 的全部 eigenvalues 一致就能换基得到彼此吗？", "matrix", true),
            ("r21", "gpu", "移动版 4070 跑模型时突然闪屏该从哪里排查？", "gpu", false),
            ("r22", "project", "这个掌上聊天助手的长期记忆层应该插在哪里？", "project", true),
            ("r23", "movie", "想看开场就抓人、角色斗脑筋的悬疑作品。", "movie", true),
            ("r24", "privacy", "我的私人文档做检索增强时能完全不出本机吗？", "privacy", true),
            ("r25", "travel", "十月份那次出国想逛二次元街区。", "tokyo", true),
            ("r26", "latex", "矩阵证明别再用纯文本挤在一行里。", "latex", true),
            ("r27", "allergy", "餐厅说酱料里有少量落花生，我能点吗？", "allergy", false),
            ("r28", "concise", "别绕弯子，结果放最前面。", "concise", true),
            ("n01", "hard-negative", "iPhone 的 OLED 屏幕为什么会烧屏？", nil, true),
            ("n02", "near-topic-negative", "微积分里的拉格朗日中值定理怎么证明？", nil, true),
            ("n03", "semantic-hard-negative", "概率论中心极限定理是什么意思？", nil, true),
            ("n04", "hard-negative", "Windows 蓝屏的常见原因有哪些？", nil, true),
            ("n05", "hard-negative", "写一个安卓相机权限示例。", nil, true),
            ("n06", "hard-negative", "讲讲法国新浪潮电影史。", nil, true),
            ("n07", "hard-negative", "东京今天的天气怎么样？", nil, true),
            ("n08", "hard-negative", "猫科动物在野外如何捕猎？", nil, true),
            ("n09", "hard-negative", "咖啡豆浅烘和深烘有什么区别？", nil, true),
            ("n10", "hard-negative", "素数有无穷多个怎么证明？", nil, true),
            ("n11", "hard-negative", "Swift 的 actor 隔离规则是什么？", nil, true),
            ("n12", "hard-negative", "Cloudflare CDN 缓存命中率怎么优化？", nil, true),
            ("n13", "hard-negative", "耳机的主动降噪原理是什么？", nil, true),
            ("n14", "hard-negative", "香港有哪些值得去的博物馆？", nil, true),
            ("n15", "hard-negative", "怎样训练半程马拉松？", nil, true),
            ("n16", "hard-negative", "Aimer 的最新专辑是什么？", nil, true)
        ]
        return q.map { value in
            let target = value.3.flatMap { ids[$0] }
            let mustNot: Set<UUID>
            switch value.0 {
            case "n01": mustNot = [ids["project"]!]
            case "n02", "n03", "n10": mustNot = [ids["linear"]!, ids["matrix"]!]
            case "n05", "n11": mustNot = [ids["project"]!, ids["swiftui"]!]
            default: mustNot = []
            }
            return .init(id: value.0, category: value.1,
                         input: .init(primaryText: value.2), mustRetrieve: target,
                         mustNotRetrieve: mustNot, lowOverlap: value.4 && target != nil)
        }
    }

    private static func record(
        id: UUID, kind: MemoryKind, text: String, scope: String, status: MemoryStatus,
        now: Date, expiresAt: Date? = nil, embeddingData: Data? = nil
    ) -> MemoryRetrievalRecord {
        .init(memory: .init(
            id: id, scopeID: scope, kindRawValue: kind.rawValue, canonicalText: text,
            embeddingData: embeddingData, importance: 0.7, confidence: 0.9,
            statusRawValue: status.rawValue, createdAt: now, updatedAt: now,
            lastConfirmedAt: now, lastReinforcedAt: nil, expiresAt: expiresAt,
            reinforcementCount: 1
        ), sources: [])
    }

    private static func staleEnvelope(text: String) -> Data? {
        let descriptor = MemoryEmbeddingDescriptor(
            provider: "obsolete-provider", modelIdentifier: "obsolete-model", revision: 0,
            dimension: 2, modelFamily: "obsolete", language: "zh-Hans", semantic: true
        )
        guard let vector = try? MemoryEmbeddingVector(descriptor: descriptor, values: [1, 0]) else { return nil }
        return try? MemoryEmbeddingEnvelope(result: vector, text: text).encoded()
    }
}

private enum MemoryEvaluationContainer {
    static func make() throws -> ModelContainer {
        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "MemorySemanticEvaluation", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
    }
}

private enum EvaluationError: LocalizedError {
    case physicalDeviceRequired
    var errorDescription: String? {
        "Step 3.5 必须在 iOS 17 或更高版本的真实 iPhone 上运行，模拟器结果不会被接受。"
    }
}

private extension Result where Success == MemoryEmbeddingVector, Failure == Error {
    var failureDescription: String? {
        if case .failure(let error) = self { return String(describing: error) }
        return nil
    }
}

enum MemorySemanticEvaluationTestHooks {
    static var benchmarkSummary: (queries: Int, relevant: Int, noResult: Int, lowOverlap: Int) {
        MemorySemanticEvaluationBenchmark.summary
    }
}
#endif
