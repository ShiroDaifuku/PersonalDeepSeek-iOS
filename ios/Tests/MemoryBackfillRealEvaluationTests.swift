import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

final class MemoryBackfillRealEvaluationTests: XCTestCase {
    // Diagnostic-only: frozen same_fact input and assertion, five fresh stores.
    // Never retry a failed trial or change the production extractor prompt.
    func testSameFactFiveIndependentTrials() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_INTEGRATION_ACCEPTANCE_EVALUATION"] == "1", "Opt-in acceptance only")
        let apiKey = try XCTUnwrap(ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"])
        var records: [[String: Any]] = []
        for trial in 1...5 {
            let container = try makeContainer()
            let store = MemoryStore(modelContainer: container)
            let newerDate = makeDate(2026, 9, 1)
            let seededID = try await store.insertMemory(scopeID: MemoryScope.localDefault, draft: .init(
                kind: .durableFact, canonicalText: "用户的电脑是 RTX 4070 Laptop。", createdAt: newerDate,
                updatedAt: newerDate, lastConfirmedAt: newerDate
            )).id
            let extractor = AcceptanceRecordingExtractor(key: apiKey)
            let processor = MemoryProcessor(store: store, extractor: extractor)
            let turn = CompletedTurnSnapshot(
                conversationID: UUID(), userMessageID: UUID(), userText: "我的电脑是 RTX 4070 Laptop。",
                assistantMessageID: UUID(), assistantText: "明白。",
                completedAt: makeDate(2024, 1, 1), origin: .historicalBackfill
            )
            let details = await processor.processCompletedTurnDetailed(turn)
            let active = try await store.listMemories(scopeID: MemoryScope.localDefault).filter { $0.status == .active }
            let seed = active.first { $0.id == seededID }
            let passed = active.count == 1 && seed?.lastConfirmedAt == newerDate
                && (seed?.reinforcementCount ?? 0) >= 1
            let extraction = await extractor.responseData()
            let raw = extraction.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
            let metrics = Self.metrics(details.result)
            records.append([
                "trial": trial, "passed": passed, "classification": Self.resultName(details.result),
                "rawExtraction": raw, "activeCount": active.count,
                "reinforcementCount": seed?.reinforcementCount ?? -1,
                "newerConfirmationPreserved": seed?.lastConfirmedAt == newerDate,
                "canonicalTextPreserved": seed?.canonicalText == "用户的电脑是 RTX 4070 Laptop。",
                "promptTokens": metrics?.promptTokens ?? 0, "completionTokens": metrics?.completionTokens ?? 0
            ])
        }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INTEGRATION_ACCEPTANCE_REPORT_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("same-fact-five-trials.json"))
        XCTAssertEqual(records.count, 5)
        // PASS/NOOP distribution is reported, not forcibly made green. Corruption is blocking.
        XCTAssertTrue(records.allSatisfy { $0["newerConfirmationPreserved"] as? Bool == true && $0["canonicalTextPreserved"] as? Bool == true })
    }

    func testHistoricalTimelineAgainstRealDeepSeek() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_REAL_MEMORY_BACKFILL_EVALUATION"] == "1",
            "Manual real-API evaluation only"
        )
        let apiKey = try XCTUnwrap(ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"])
        let cases: [EvaluationCase] = [
            .init(name: "same_fact", user: "我的电脑是 RTX 4070 Laptop。", assistant: "明白。", expected: "reinforced", seed: .durableFact, seedText: "用户的电脑是 RTX 4070 Laptop。"),
            .init(name: "old_vs_new_preference", user: "我喜欢慢节奏电影。", assistant: "知道了。", expected: "newer_wins", seed: .preference, seedText: "用户偏好节奏紧凑的电影。"),
            .init(name: "expired_recent", user: "我这几天在复习线性代数。", assistant: "好的。", expected: "noop", seed: nil, seedText: nil),
            .init(name: "expired_ongoing", user: "我正在做项目 A。", assistant: "好的。", expected: "noop", seed: nil, seedText: nil),
            .init(name: "durable", user: "我是建筑学本科生。", assistant: "明白。", expected: "active", seed: nil, seedText: nil),
            .init(name: "event", user: "我已经看完《海边的卡夫卡》了，之后可以剧透。", assistant: "明白。", expected: "active", seed: nil, seedText: nil),
            .init(name: "ordinary_noop", user: "矩阵的秩是什么意思？", assistant: "矩阵的秩是线性无关行或列的最大数量。", expected: "noop", seed: nil, seedText: nil),
            .init(name: "third_party", user: "我朋友最近在复习线性代数。", assistant: "祝他复习顺利。", expected: "noop", seed: nil, seedText: nil),
            .init(name: "hypothetical", user: "假设我住在东京，通勤该怎么规划？", assistant: "可以按线路和时段规划。", expected: "noop", seed: nil, seedText: nil)
        ]
        var records: [EvaluationRecord] = []
        for item in cases {
            let container = try makeContainer()
            let store = MemoryStore(modelContainer: container)
            let newerDate = makeDate(2026, 9, 1)
            var seededID: UUID?
            if let kind = item.seed, let text = item.seedText {
                seededID = try await store.insertMemory(scopeID: MemoryScope.localDefault, draft: .init(
                    kind: kind, canonicalText: text, createdAt: newerDate,
                    updatedAt: newerDate, lastConfirmedAt: newerDate
                )).id
            }
            let processor = MemoryProcessor(store: store, extractor: MemoryExtractionClient(apiKeyOverride: apiKey))
            let turn = CompletedTurnSnapshot(
                conversationID: UUID(), userMessageID: UUID(), userText: item.user,
                assistantMessageID: UUID(), assistantText: item.assistant,
                completedAt: makeDate(2024, 1, 1), origin: .historicalBackfill
            )
            let details = await processor.processCompletedTurnDetailed(turn)
            let memories = try await store.listMemories(scopeID: MemoryScope.localDefault)
            let active = memories.filter { $0.status == .active }
            let passed: Bool
            switch item.expected {
            case "reinforced":
                let seed = active.first { $0.id == seededID }
                passed = active.count == 1 && seed?.lastConfirmedAt == newerDate
                    && (seed?.reinforcementCount ?? 0) >= 1
            case "newer_wins":
                passed = active.count == 1 && active.first?.id == seededID
                    && active.first?.lastConfirmedAt == newerDate
            case "active":
                passed = active.count == 1 && active.first?.lastConfirmedAt == turn.completedAt
            default:
                passed = active.isEmpty
            }
            let metrics = Self.metrics(details.result)
            records.append(.init(
                name: item.name,
                passed: passed,
                result: Self.resultName(details.result),
                activeCount: active.count,
                skippedExpired: details.skippedExpiredEphemeral,
                skippedTemporal: details.skippedTemporalConflict,
                promptTokens: metrics?.promptTokens,
                completionTokens: metrics?.completionTokens,
                totalTokens: metrics?.totalTokens
            ))
            XCTAssertTrue(passed, "Historical case failed: \(item.name)")
        }
        try writeReport(records)
    }

    private static func metrics(_ result: MemoryProcessingResult) -> MemoryExtractionMetrics? {
        switch result {
        case .processed(_, let metrics), .noop(let metrics): metrics
        case .alreadyProcessed, .failed: nil
        }
    }

    private static func resultName(_ result: MemoryProcessingResult) -> String {
        switch result {
        case .processed: "processed"
        case .noop: "noop"
        case .alreadyProcessed: "already_processed"
        case .failed(let code): "failed:\(code)"
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "BackfillRealEvaluation", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0), year: year, month: month, day: day
        ))!
    }

    private func writeReport(_ records: [EvaluationRecord]) throws {
        guard let raw = ProcessInfo.processInfo.environment["MEMORY_BACKFILL_REPORT_DIR"] else { return }
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: directory.appendingPathComponent("memory-backfill-evaluation.json"))
        let prompt = records.compactMap(\.promptTokens).reduce(0, +)
        let completion = records.compactMap(\.completionTokens).reduce(0, +)
        let total = records.compactMap(\.totalTokens).reduce(0, +)
        let missing = records.filter { $0.totalTokens == nil }.count
        var lines = [
            "# Historical Memory Backfill Real Evaluation", "",
            "- Cases: \(records.count)",
            "- Passed: \(records.filter(\.passed).count)",
            "- Prompt tokens: \(prompt)",
            "- Completion tokens: \(completion)",
            "- Total tokens: \(total)",
            "- Missing usage: \(missing)", ""
        ]
        lines += records.map { "- \($0.name): \($0.passed ? "PASS" : "FAIL") (\($0.result))" }
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("memory-backfill-evaluation.md"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private actor AcceptanceRecordingExtractor: MemoryExtracting {
    nonisolated let modelName = MemoryExtractionConfiguration.modelName
    private let underlying: MemoryExtractionClient
    private var data: Data?
    init(key: String) { underlying = MemoryExtractionClient(apiKeyOverride: key) }
    func extract(turn: CompletedTurnSnapshot, candidates: [ExistingMemoryCandidate]) async throws -> MemoryExtractionOutput {
        let value = try await underlying.extract(turn: turn, candidates: candidates)
        data = try JSONEncoder().encode(value.response)
        return value
    }
    func responseData() -> Data? { data }
}

private struct EvaluationCase {
    let name: String
    let user: String
    let assistant: String
    let expected: String
    let seed: MemoryKind?
    let seedText: String?
}

private struct EvaluationRecord: Codable {
    let name: String
    let passed: Bool
    let result: String
    let activeCount: Int
    let skippedExpired: Int
    let skippedTemporal: Int
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
}
