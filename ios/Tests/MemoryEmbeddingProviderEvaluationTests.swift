import Foundation
import XCTest
@testable import PersonalDeepSeek

final class MemoryEmbeddingProviderEvaluationTests: XCTestCase {
    private struct CorpusEntry: Sendable {
        let id: String
        let text: String
        let category: String
    }

    private struct QueryCase: Sendable {
        let id: String
        let query: String
        let expectedID: String?
        let category: String
    }

    private struct CandidateScore: Sendable {
        let id: String
        let score: Double
    }

    private struct ProviderReport: Codable {
        let provider: String
        let semantic: Bool
        let available: Bool
        let selectedThreshold: Double?
        let recallAt1: Double?
        let recallAt3: Double?
        let recallAt5: Double?
        let meanReciprocalRank: Double?
        let noResultAccuracy: Double?
        let falseRetrievalRate: Double?
        let chineseRecallAt3: Double?
        let mixedRecallAt3: Double?
        let medianLatencyMilliseconds: Double?
        let p95LatencyMilliseconds: Double?
        let availability: [MemoryEmbeddingAvailability]
        let failures: [String]
    }

    private struct EvaluationReport: Codable {
        let generatedAt: Date
        let corpusCount: Int
        let queryCount: Int
        let relevantQueryCount: Int
        let noResultQueryCount: Int
        let poolingStrategy: String
        let hashFallbackAudit: String
        let providers: [ProviderReport]
    }

    func testEmbeddingProvidersAgainstMultilingualBenchmark() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_MEMORY_PROVIDER_EVALUATION"] == "1",
            "Manual provider evaluation; set RUN_MEMORY_PROVIDER_EVALUATION=1"
        )

        let requestAssets = ProcessInfo.processInfo.environment["REQUEST_CONTEXTUAL_ASSETS"] == "1"
        var reports: [ProviderReport] = []
        reports.append(evaluateLexicalBaseline())
        reports.append(await evaluate(provider: NLSentenceMemoryEmbeddingProvider()))

        if #available(iOS 17.0, *) {
            let contextual = NLContextualMemoryEmbeddingProvider()
            _ = await contextual.prepare(for: "用户喜欢用 SwiftUI 写 iOS 应用", requestAssetDownload: requestAssets)
            _ = await contextual.prepare(for: "The user prefers TypeScript for backend services", requestAssetDownload: requestAssets)
            reports.append(await evaluate(provider: contextual))
        }

        let report = EvaluationReport(
            generatedAt: Date(),
            corpusCount: Self.corpus.count,
            queryCount: Self.queries.count,
            relevantQueryCount: Self.queries.filter { $0.expectedID != nil }.count,
            noResultQueryCount: Self.queries.filter { $0.expectedID == nil }.count,
            poolingStrategy: "NLContextualEmbedding: arithmetic mean of every returned subword token vector, followed by L2 normalization.",
            hashFallbackAudit: "The existing 128-dimensional deterministic fallback is SHA-256 feature hashing over lexical tokens and CJK uni/bi-grams. It is not semantic and is evaluated only as a lexical/hash fallback.",
            providers: reports
        )
        try write(report)

        XCTAssertGreaterThanOrEqual(Self.queries.count, 30)
        XCTAssertTrue(reports.contains { $0.provider == "lexical-only-baseline" && $0.available })
        XCTAssertTrue(reports.contains { $0.provider == "apple-nl-sentence" })
    }

    private func evaluate<P: MemoryEmbeddingProvider>(provider: P) async -> ProviderReport {
        var availability: [MemoryEmbeddingAvailability] = []
        availability.append(await provider.availability(for: "用户喜欢用 SwiftUI 写 iOS 应用"))
        availability.append(await provider.availability(for: "The user prefers TypeScript for backend services"))

        var corpusVectors: [String: [Float]] = [:]
        var failures: [String] = []
        var latencies: [Double] = []
        for entry in Self.corpus {
            let started = ContinuousClock.now
            do { corpusVectors[entry.id] = try await provider.embedding(for: entry.text).values }
            catch { failures.append("corpus/\(entry.id): \(error)") }
            latencies.append(milliseconds(since: started))
        }

        var raw: [String: [CandidateScore]] = [:]
        for query in Self.queries {
            let started = ContinuousClock.now
            do {
                let vector = try await provider.embedding(for: query.query).values
                raw[query.id] = corpusVectors.compactMap { id, candidate in
                    MemoryVectorMath.cosine(vector, candidate).map { CandidateScore(id: id, score: $0) }
                }.sorted { $0.score > $1.score }
            } catch { failures.append("query/\(query.id): \(error)") }
            latencies.append(milliseconds(since: started))
        }

        guard !corpusVectors.isEmpty, !raw.isEmpty else {
            return .init(
                provider: provider.providerIdentifier, semantic: provider.isSemantic, available: false,
                selectedThreshold: nil, recallAt1: nil, recallAt3: nil, recallAt5: nil,
                meanReciprocalRank: nil, noResultAccuracy: nil, falseRetrievalRate: nil,
                chineseRecallAt3: nil, mixedRecallAt3: nil,
                medianLatencyMilliseconds: percentile(latencies, 0.5),
                p95LatencyMilliseconds: percentile(latencies, 0.95), availability: availability, failures: failures
            )
        }

        let selected = selectThreshold(raw: raw)
        return metrics(
            provider: provider.providerIdentifier,
            semantic: provider.isSemantic,
            availability: availability,
            failures: failures,
            latencies: latencies,
            raw: raw,
            threshold: selected
        )
    }

    private func evaluateLexicalBaseline() -> ProviderReport {
        var raw: [String: [CandidateScore]] = [:]
        var latencies: [Double] = []
        for query in Self.queries {
            let started = ContinuousClock.now
            raw[query.id] = Self.corpus.map { entry in
                CandidateScore(id: entry.id, score: Self.lexicalScore(query.query, entry.text))
            }.sorted { $0.score > $1.score }
            latencies.append(milliseconds(since: started))
        }
        let threshold = selectThreshold(raw: raw)
        return metrics(
            provider: "lexical-only-baseline", semantic: false,
            availability: [.init(
                provider: "lexical-only-baseline", modelIdentifier: "token-overlap-v1", revision: 1,
                dimension: nil, modelFamily: "lexical/entity", language: "multilingual", semantic: false,
                hasAvailableAssets: true, loaded: true, detail: "Normalized token, CJK bi-gram, containment, and entity overlap"
            )], failures: [], latencies: latencies, raw: raw, threshold: threshold
        )
    }

    private func selectThreshold(raw: [String: [CandidateScore]]) -> Double {
        let values = stride(from: 0.10, through: 0.90, by: 0.01)
        return values.max { lhs, rhs in
            let left = thresholdObjective(raw: raw, threshold: lhs)
            let right = thresholdObjective(raw: raw, threshold: rhs)
            if left.precision != right.precision { return left.precision < right.precision }
            if left.noResult != right.noResult { return left.noResult < right.noResult }
            return left.recall < right.recall
        } ?? 0.5
    }

    private func thresholdObjective(raw: [String: [CandidateScore]], threshold: Double) -> (precision: Double, noResult: Double, recall: Double) {
        var truePositive = 0
        var returned = 0
        var relevant = 0
        var noResultCorrect = 0
        var noResultCount = 0
        for query in Self.queries {
            let accepted = (raw[query.id] ?? []).filter { $0.score >= threshold }.prefix(3)
            if let expected = query.expectedID {
                relevant += 1
                returned += accepted.count
                truePositive += accepted.filter { $0.id == expected }.count
            } else {
                noResultCount += 1
                returned += accepted.count
                if accepted.isEmpty { noResultCorrect += 1 }
            }
        }
        return (
            returned == 0 ? 1 : Double(truePositive) / Double(returned),
            noResultCount == 0 ? 1 : Double(noResultCorrect) / Double(noResultCount),
            relevant == 0 ? 1 : Double(truePositive) / Double(relevant)
        )
    }

    private func metrics(
        provider: String,
        semantic: Bool,
        availability: [MemoryEmbeddingAvailability],
        failures: [String],
        latencies: [Double],
        raw: [String: [CandidateScore]],
        threshold: Double
    ) -> ProviderReport {
        let relevant = Self.queries.filter { $0.expectedID != nil }
        let noResult = Self.queries.filter { $0.expectedID == nil }
        func recall(_ limit: Int, category: String? = nil) -> Double {
            let selected = relevant.filter { category == nil || $0.category == category }
            guard !selected.isEmpty else { return 1 }
            let hits = selected.filter { query in
                (raw[query.id] ?? []).filter { $0.score >= threshold }.prefix(limit).contains { $0.id == query.expectedID }
            }.count
            return Double(hits) / Double(selected.count)
        }
        let reciprocalRanks = relevant.map { query -> Double in
            guard let expected = query.expectedID,
                  let index = (raw[query.id] ?? []).filter({ $0.score >= threshold }).firstIndex(where: { $0.id == expected })
            else { return 0 }
            return 1 / Double(index + 1)
        }
        let noResultCorrect = noResult.filter { query in
            !(raw[query.id] ?? []).contains { $0.score >= threshold }
        }.count
        let falseRetrievals = noResult.filter { query in
            (raw[query.id] ?? []).contains { $0.score >= threshold }
        }.count
        return .init(
            provider: provider, semantic: semantic, available: true, selectedThreshold: threshold,
            recallAt1: recall(1), recallAt3: recall(3), recallAt5: recall(5),
            meanReciprocalRank: reciprocalRanks.reduce(0, +) / Double(max(reciprocalRanks.count, 1)),
            noResultAccuracy: Double(noResultCorrect) / Double(max(noResult.count, 1)),
            falseRetrievalRate: Double(falseRetrievals) / Double(max(noResult.count, 1)),
            chineseRecallAt3: recall(3, category: "zh"), mixedRecallAt3: recall(3, category: "mixed"),
            medianLatencyMilliseconds: percentile(latencies, 0.5), p95LatencyMilliseconds: percentile(latencies, 0.95),
            availability: availability, failures: failures
        )
    }

    private func milliseconds(since instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: .now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
        return sorted[index]
    }

    private func write(_ report: EvaluationReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let directory = FileManager.default.temporaryDirectory
        try data.write(to: directory.appendingPathComponent("memory-provider-evaluation.json"), options: .atomic)

        var markdown = "# Memory Embedding Provider Evaluation\n\n"
        markdown += "Corpus: \(report.corpusCount), queries: \(report.queryCount), relevant: \(report.relevantQueryCount), no-result: \(report.noResultQueryCount).\n\n"
        markdown += "Pooling: \(report.poolingStrategy)\n\nHash fallback audit: \(report.hashFallbackAudit)\n\n"
        markdown += "| Provider | Semantic | Available | Threshold | R@1 | R@3 | R@5 | MRR | No-result | False retrieval | zh R@3 | mixed R@3 | p50 ms | p95 ms |\n"
        markdown += "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n"
        for value in report.providers {
            func f(_ number: Double?) -> String { number.map { String(format: "%.3f", $0) } ?? "n/a" }
            markdown += "| \(value.provider) | \(value.semantic) | \(value.available) | \(f(value.selectedThreshold)) | \(f(value.recallAt1)) | \(f(value.recallAt3)) | \(f(value.recallAt5)) | \(f(value.meanReciprocalRank)) | \(f(value.noResultAccuracy)) | \(f(value.falseRetrievalRate)) | \(f(value.chineseRecallAt3)) | \(f(value.mixedRecallAt3)) | \(f(value.medianLatencyMilliseconds)) | \(f(value.p95LatencyMilliseconds)) |\n"
            for state in value.availability {
                markdown += "\n- `\(value.provider)` / `\(state.language)`: assets=\(state.hasAvailableAssets), loaded=\(state.loaded), model=\(state.modelIdentifier ?? "n/a"), revision=\(state.revision.map(String.init) ?? "n/a"), dimension=\(state.dimension.map(String.init) ?? "n/a") — \(state.detail)\n"
            }
            if !value.failures.isEmpty { markdown += "\n- failures: \(value.failures.joined(separator: "; "))\n" }
        }
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("memory-provider-evaluation.md"), options: .atomic)
    }

    private static func lexicalScore(_ lhs: String, _ rhs: String) -> Double {
        let left = features(lhs)
        let right = features(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let overlap = left.intersection(right).count
        let dice = 2 * Double(overlap) / Double(left.count + right.count)
        let normalizedLeft = MemoryEmbeddingText.normalized(lhs)
        let normalizedRight = MemoryEmbeddingText.normalized(rhs)
        let containment = normalizedLeft.count >= 2 && (normalizedLeft.contains(normalizedRight) || normalizedRight.contains(normalizedLeft)) ? 1.0 : 0
        let entity = entities(lhs).intersection(entities(rhs)).isEmpty ? 0.0 : 1.0
        return min(1, 0.65 * dice + 0.20 * containment + 0.15 * entity)
    }

    private static func features(_ text: String) -> Set<String> {
        let normalized = MemoryEmbeddingText.normalized(text)
        var result = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
        let cjk = Array(normalized.filter { $0.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } })
        result.formUnion(cjk.map(String.init))
        if cjk.count > 1 { result.formUnion((0..<(cjk.count - 1)).map { String([cjk[$0], cjk[$0 + 1]]) }) }
        return result
    }

    private static func entities(_ text: String) -> Set<String> {
        Set(text.split { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "#" }
            .map(String.init).filter { token in token.count >= 2 && (token.first?.isUppercase == true || token.contains(where: { $0.isNumber })) })
    }

    private static let corpus: [CorpusEntry] = [
        .init(id: "swiftui", text: "用户偏好使用 SwiftUI 开发 iOS 客户端", category: "mixed"),
        .init(id: "typescript", text: "用户更喜欢 TypeScript 编写 Cloudflare Workers 后端", category: "mixed"),
        .init(id: "dark", text: "用户喜欢深色模式和低亮度界面", category: "zh"),
        .init(id: "coffee", text: "用户每天早晨喝不加糖的拿铁咖啡", category: "zh"),
        .init(id: "cat", text: "用户养了一只名叫糯米的橘猫", category: "zh"),
        .init(id: "tokyo", text: "用户计划十月去东京旅行并参观秋叶原", category: "zh"),
        .init(id: "latex", text: "用户希望数学答案使用 LaTeX 公式排版", category: "mixed"),
        .init(id: "bangdream", text: "用户近期关注 BanG Dream! Our Notes 的开服消息", category: "mixed"),
        .init(id: "deepseek", text: "用户的助手项目统一接入 DeepSeek API", category: "mixed"),
        .init(id: "allergy", text: "用户对花生严重过敏，饮食建议必须避开花生", category: "zh"),
        .init(id: "vegetarian", text: "用户平时吃素，不希望推荐含肉菜品", category: "zh"),
        .init(id: "math", text: "用户正在复习线性代数中的特征值与特征向量", category: "zh"),
        .init(id: "music", text: "用户常听 YOASOBI 和 Aimer 的歌曲", category: "mixed"),
        .init(id: "device", text: "用户的主力手机是 iPhone 17 Pro", category: "mixed"),
        .init(id: "timezone", text: "用户通常位于香港时区 Asia/Hong_Kong", category: "mixed"),
        .init(id: "budget", text: "用户购买耳机的预算不超过两千元", category: "zh"),
        .init(id: "concise", text: "用户偏好先给结论再给简洁解释", category: "zh"),
        .init(id: "python", text: "用户正在用 Python 学习数据分析和 pandas", category: "mixed"),
        .init(id: "running", text: "用户每周三和周六晚上跑步五公里", category: "zh"),
        .init(id: "privacy", text: "用户重视隐私，不希望把本地笔记上传到云端", category: "zh")
    ]

    private static let queries: [QueryCase] = [
        .init(id: "q01", query: "我写 iPhone 界面时更爱用什么框架？", expectedID: "swiftui", category: "zh"),
        .init(id: "q02", query: "Which UI framework do I prefer for iOS apps?", expectedID: "swiftui", category: "mixed"),
        .init(id: "q03", query: "Cloudflare 后端我倾向哪种语言？", expectedID: "typescript", category: "mixed"),
        .init(id: "q04", query: "界面主题方面我有什么偏好？", expectedID: "dark", category: "zh"),
        .init(id: "q05", query: "我早上通常喝什么？", expectedID: "coffee", category: "zh"),
        .init(id: "q06", query: "我的宠物叫什么名字？", expectedID: "cat", category: "zh"),
        .init(id: "q07", query: "糯米是什么？", expectedID: "cat", category: "zh"),
        .init(id: "q08", query: "十月的旅行计划去哪里？", expectedID: "tokyo", category: "zh"),
        .init(id: "q09", query: "How should equations be formatted in answers?", expectedID: "latex", category: "mixed"),
        .init(id: "q10", query: "我最近在等哪款 BanG Dream 游戏？", expectedID: "bangdream", category: "mixed"),
        .init(id: "q11", query: "助手项目使用哪家的模型接口？", expectedID: "deepseek", category: "zh"),
        .init(id: "q12", query: "给我推荐零食时必须避开什么？", expectedID: "allergy", category: "zh"),
        .init(id: "q13", query: "我能不能吃含花生酱的甜点？", expectedID: "allergy", category: "zh"),
        .init(id: "q14", query: "推荐晚餐要遵守什么饮食习惯？", expectedID: "vegetarian", category: "zh"),
        .init(id: "q15", query: "我最近复习的数学章节是什么？", expectedID: "math", category: "zh"),
        .init(id: "q16", query: "我常听哪些日本歌手？", expectedID: "music", category: "zh"),
        .init(id: "q17", query: "What is my primary phone model?", expectedID: "device", category: "mixed"),
        .init(id: "q18", query: "安排提醒时该用哪个 timezone？", expectedID: "timezone", category: "mixed"),
        .init(id: "q19", query: "耳机最多准备花多少钱？", expectedID: "budget", category: "zh"),
        .init(id: "q20", query: "回答风格应该详细铺垫还是先说结论？", expectedID: "concise", category: "zh"),
        .init(id: "q21", query: "我用什么语言做 pandas 数据分析？", expectedID: "python", category: "mixed"),
        .init(id: "q22", query: "一周哪两天安排跑步？", expectedID: "running", category: "zh"),
        .init(id: "q23", query: "处理我的本地笔记时要注意什么？", expectedID: "privacy", category: "zh"),
        .init(id: "q24", query: "不要上传笔记是出于什么偏好？", expectedID: "privacy", category: "zh"),
        .init(id: "q25", query: "法国首都是什么？", expectedID: nil, category: "none"),
        .init(id: "q26", query: "今天北京天气怎么样？", expectedID: nil, category: "none"),
        .init(id: "q27", query: "求解二次方程 x²+3x+2=0", expectedID: nil, category: "none"),
        .init(id: "q28", query: "帮我解释黑洞的霍金辐射", expectedID: nil, category: "none"),
        .init(id: "q29", query: "最新美元汇率是多少？", expectedID: nil, category: "none"),
        .init(id: "q30", query: "写一首关于大海的诗", expectedID: nil, category: "none"),
        .init(id: "q31", query: "How tall is Mount Everest?", expectedID: nil, category: "none"),
        .init(id: "q32", query: "解释牛顿第二定律", expectedID: nil, category: "none"),
        .init(id: "q33", query: "附近有什么好吃的餐厅？", expectedID: nil, category: "none"),
        .init(id: "q34", query: "把这句话翻译成法语", expectedID: nil, category: "none"),
        .init(id: "q35", query: "量子计算机如何纠错？", expectedID: nil, category: "none"),
        .init(id: "q36", query: "明天会下雨吗？", expectedID: nil, category: "none")
    ]
}
