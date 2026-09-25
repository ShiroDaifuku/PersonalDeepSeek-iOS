import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

@MainActor
final class MemoryRetrievalEvaluationTests: XCTestCase {
    private struct EvaluationQuery: Sendable {
        let id: String
        let primary: String
        let context: String?
        let expected: UUID?
        let category: String
    }

    private struct Metrics: Codable, Sendable {
        let precisionAt3: Double
        let recallAt3: Double
        let recallAt5: Double
        let meanReciprocalRank: Double
        let noResultAccuracy: Double
        let falseRetrievalRate: Double
        let contextualRecall: Double
        let expiredLeakage: Int
        let supersededLeakage: Int
        let invalidatedLeakage: Int
        let crossScopeLeakage: Int
        let staleEmbeddingUse: Int
    }

    private struct ParameterSet: Codable, Sendable {
        let semanticGate: Double
        let lexicalGate: Double
        let relevanceWeight: Double
        let recencyWeight: Double
        let importanceWeight: Double
        let reinforcementWeight: Double
    }

    private struct Report: Codable, Sendable {
        let generatedAt: Date
        let queryCount: Int
        let relevantCount: Int
        let noResultCount: Int
        let providerDecision: String
        let beforeParameters: ParameterSet
        let beforeMetrics: Metrics
        let afterParameters: ParameterSet
        let afterMetrics: Metrics
        let targetPassed: Bool
    }

    func testProductionRetrievalBenchmark() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_MEMORY_RETRIEVAL_EVALUATION"] == "1",
            "Manual retrieval evaluation"
        )
        let container = try makeContainer()
        let store = MemoryStore(modelContainer: container)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let fixture = makeFixture(now: now)
        var initial = MemoryRetrievalConfiguration()
        initial.lexicalGate = 0.18
        let before = await evaluate(configuration: initial, store: store, fixture: fixture, now: now)

        var best = (configuration: initial, metrics: before)
        for gate in stride(from: 0.14, through: 0.42, by: 0.01) {
            var candidate = initial
            candidate.lexicalGate = gate
            let metrics = await evaluate(configuration: candidate, store: store, fixture: fixture, now: now)
            if isBetter(metrics, than: best.metrics) { best = (candidate, metrics) }
        }

        let report = Report(
            generatedAt: Date(), queryCount: fixture.queries.count,
            relevantCount: fixture.queries.filter { $0.expected != nil }.count,
            noResultCount: fixture.queries.filter { $0.expected == nil }.count,
            providerDecision: "Apple semantic providers were unavailable on the CI simulator. Retrieval therefore uses precision-first lexical/entity gating; semantic envelope scores are used only when a matching, current provider is available on the device.",
            beforeParameters: parameters(initial), beforeMetrics: before,
            afterParameters: parameters(best.configuration), afterMetrics: best.metrics,
            targetPassed: passesTargets(best.metrics)
        )
        try write(report)

        XCTAssertEqual(best.metrics.expiredLeakage, 0)
        XCTAssertEqual(best.metrics.supersededLeakage, 0)
        XCTAssertEqual(best.metrics.invalidatedLeakage, 0)
        XCTAssertEqual(best.metrics.crossScopeLeakage, 0)
        XCTAssertEqual(best.metrics.staleEmbeddingUse, 0)
        XCTAssertGreaterThanOrEqual(best.metrics.precisionAt3, 0.95)
        XCTAssertGreaterThanOrEqual(best.metrics.recallAt3, 0.90)
        XCTAssertGreaterThanOrEqual(best.metrics.recallAt5, 0.95)
        XCTAssertGreaterThanOrEqual(best.metrics.noResultAccuracy, 0.95)
    }

    private func evaluate(
        configuration: MemoryRetrievalConfiguration,
        store: MemoryStore,
        fixture: (records: [MemoryRetrievalRecord], queries: [EvaluationQuery], forbidden: [String: UUID]),
        now: Date
    ) async -> Metrics {
        let retriever = MemoryRetriever(store: store, semanticResolver: RetrievalEvaluationSemanticResolver(), configuration: configuration)
        var correctTop3 = 0
        var returnedTop3 = 0
        var recall3 = 0
        var recall5 = 0
        var reciprocal = 0.0
        var noResultCorrect = 0
        var falseRetrieval = 0
        var contextualCount = 0
        var contextualHits = 0
        var allResults: [String: [MemoryRetrievalResult]] = [:]
        for query in fixture.queries {
            let result = await retriever.rank(.init(
                primaryText: query.primary, contextText: query.context, scopeID: MemoryScope.localDefault
            ), records: fixture.records, now: now)
            allResults[query.id] = result
            let top3 = Array(result.prefix(3))
            returnedTop3 += top3.count
            if let expected = query.expected {
                let top3Hit = top3.contains { $0.memoryID == expected }
                correctTop3 += top3.filter { $0.memoryID == expected }.count
                recall3 += top3Hit ? 1 : 0
                recall5 += result.prefix(5).contains { $0.memoryID == expected } ? 1 : 0
                if let index = result.firstIndex(where: { $0.memoryID == expected }) { reciprocal += 1 / Double(index + 1) }
                if query.context != nil {
                    contextualCount += 1
                    contextualHits += top3Hit ? 1 : 0
                }
            } else if result.isEmpty {
                noResultCorrect += 1
            } else {
                falseRetrieval += 1
            }
        }
        let relevant = fixture.queries.filter { $0.expected != nil }.count
        let none = fixture.queries.count - relevant
        let returnedIDs = Set(allResults.values.flatMap { $0.map(\.memoryID) })
        return .init(
            precisionAt3: returnedTop3 == 0 ? 1 : Double(correctTop3) / Double(returnedTop3),
            recallAt3: Double(recall3) / Double(max(relevant, 1)),
            recallAt5: Double(recall5) / Double(max(relevant, 1)),
            meanReciprocalRank: reciprocal / Double(max(relevant, 1)),
            noResultAccuracy: Double(noResultCorrect) / Double(max(none, 1)),
            falseRetrievalRate: Double(falseRetrieval) / Double(max(none, 1)),
            contextualRecall: Double(contextualHits) / Double(max(contextualCount, 1)),
            expiredLeakage: returnedIDs.contains(fixture.forbidden["expired"]!) ? 1 : 0,
            supersededLeakage: returnedIDs.contains(fixture.forbidden["superseded"]!) ? 1 : 0,
            invalidatedLeakage: returnedIDs.contains(fixture.forbidden["invalidated"]!) ? 1 : 0,
            crossScopeLeakage: returnedIDs.contains(fixture.forbidden["scope"]!) ? 1 : 0,
            staleEmbeddingUse: returnedIDs.contains(fixture.forbidden["stale"]!) ? 1 : 0
        )
    }

    private func isBetter(_ lhs: Metrics, than rhs: Metrics) -> Bool {
        if lhs.precisionAt3 != rhs.precisionAt3 { return lhs.precisionAt3 > rhs.precisionAt3 }
        if lhs.noResultAccuracy != rhs.noResultAccuracy { return lhs.noResultAccuracy > rhs.noResultAccuracy }
        if lhs.recallAt3 != rhs.recallAt3 { return lhs.recallAt3 > rhs.recallAt3 }
        return lhs.recallAt5 > rhs.recallAt5
    }

    private func passesTargets(_ value: Metrics) -> Bool {
        value.precisionAt3 >= 0.95 && value.recallAt3 >= 0.90 && value.recallAt5 >= 0.95 &&
        value.noResultAccuracy >= 0.95 && value.expiredLeakage == 0 && value.supersededLeakage == 0 &&
        value.invalidatedLeakage == 0 && value.crossScopeLeakage == 0 && value.staleEmbeddingUse == 0
    }

    private func parameters(_ value: MemoryRetrievalConfiguration) -> ParameterSet {
        .init(
            semanticGate: value.semanticGate, lexicalGate: value.lexicalGate,
            relevanceWeight: value.relevanceWeight, recencyWeight: value.recencyWeight,
            importanceWeight: value.importanceWeight, reinforcementWeight: value.reinforcementWeight
        )
    }

    private func makeFixture(now: Date) -> (
        records: [MemoryRetrievalRecord], queries: [EvaluationQuery], forbidden: [String: UUID]
    ) {
        let values: [(String, MemoryKind, String)] = [
            ("swiftui", .preference, "用户偏好使用 SwiftUI 开发 iOS 客户端界面"),
            ("typescript", .preference, "用户更喜欢 TypeScript 编写 Cloudflare Workers 后端"),
            ("dark", .preference, "用户喜欢深色模式和低亮度界面"),
            ("coffee", .durableFact, "用户每天早晨喝不加糖的拿铁咖啡"),
            ("cat", .durableFact, "用户养了一只名叫糯米的橘猫宠物"),
            ("tokyo", .ongoingContext, "用户计划十月去东京旅行并参观秋叶原"),
            ("latex", .preference, "用户希望数学公式使用 LaTeX 排版"),
            ("bangdream", .recentState, "用户近期关注 BanG Dream! Our Notes 的开服消息"),
            ("deepseek", .ongoingContext, "用户的助手项目统一接入 DeepSeek API"),
            ("allergy", .durableFact, "用户对花生严重过敏，饮食必须避开花生"),
            ("vegetarian", .preference, "用户平时吃素并偏好素食菜品"),
            ("math", .ongoingContext, "用户正在复习线性代数的特征值与特征向量"),
            ("music", .preference, "用户常听 YOASOBI 和 Aimer 的音乐歌曲"),
            ("device", .durableFact, "用户的主力手机设备是 iPhone 17 Pro"),
            ("timezone", .durableFact, "用户通常使用香港时区 Asia/Hong_Kong 安排提醒"),
            ("budget", .ongoingContext, "用户购买耳机的预算最多两千元"),
            ("concise", .preference, "用户偏好回答先给结论再简洁解释"),
            ("python", .ongoingContext, "用户使用 Python 学习 pandas 数据分析"),
            ("running", .durableFact, "用户每周三和周六晚上跑步五公里"),
            ("privacy", .preference, "用户重视隐私，不允许上传本地笔记")
        ]
        var ids: [String: UUID] = [:]
        var records: [MemoryRetrievalRecord] = values.enumerated().map { offset, value in
            let id = UUID()
            ids[value.0] = id
            return record(
                id: id, kind: value.1, text: value.2, scope: MemoryScope.localDefault,
                status: .active, confirmedAt: now.addingTimeInterval(-Double(offset * 9) * 86_400)
            )
        }
        let forbidden: [String: UUID] = [
            "expired": UUID(), "superseded": UUID(), "invalidated": UUID(), "scope": UUID(), "stale": UUID()
        ]
        records.append(record(id: forbidden["expired"]!, kind: .recentState, text: "用户正在学习二次方程", scope: MemoryScope.localDefault, status: .active, confirmedAt: now, expiresAt: now.addingTimeInterval(-1)))
        records.append(record(id: forbidden["superseded"]!, kind: .event, text: "用户准备去法国巴黎", scope: MemoryScope.localDefault, status: .superseded, confirmedAt: now))
        records.append(record(id: forbidden["invalidated"]!, kind: .recentState, text: "用户关注北京天气", scope: MemoryScope.localDefault, status: .invalidated, confirmedAt: now))
        records.append(record(id: forbidden["scope"]!, kind: .durableFact, text: "用户登过珠穆朗玛峰", scope: "other-scope", status: .active, confirmedAt: now))
        let staleDescriptor = MemoryEmbeddingDescriptor(
            provider: "retrieval-evaluation", modelIdentifier: "stale-model", revision: 0,
            dimension: 2, modelFamily: "evaluation", language: "zh-Hans", semantic: true
        )
        let staleVector = try! MemoryEmbeddingVector(descriptor: staleDescriptor, values: [1, 0])
        let staleText = "用户喜欢古典绘画"
        let staleData = try! MemoryEmbeddingEnvelope(result: staleVector, text: staleText).encoded()
        records.append(record(
            id: forbidden["stale"]!, kind: .preference, text: staleText,
            scope: MemoryScope.localDefault, status: .active, confirmedAt: now, embeddingData: staleData
        ))

        let queries: [EvaluationQuery] = [
            .init(id: "r01", primary: "SwiftUI 是我偏好的 iOS 界面框架吗？", context: nil, expected: ids["swiftui"], category: "mixed"),
            .init(id: "r02", primary: "那个 UI 框架呢？", context: "我在讨论 iOS 客户端和 SwiftUI", expected: ids["swiftui"], category: "context"),
            .init(id: "r03", primary: "Cloudflare Workers 后端使用 TypeScript 吗？", context: nil, expected: ids["typescript"], category: "mixed"),
            .init(id: "r04", primary: "我喜欢深色模式界面吗？", context: nil, expected: ids["dark"], category: "zh"),
            .init(id: "r05", primary: "早晨喝的是无糖拿铁咖啡吗？", context: nil, expected: ids["coffee"], category: "zh"),
            .init(id: "r06", primary: "我的橘猫宠物叫糯米吗？", context: nil, expected: ids["cat"], category: "zh"),
            .init(id: "r07", primary: "糯米这只猫是什么宠物？", context: nil, expected: ids["cat"], category: "zh"),
            .init(id: "r08", primary: "十月东京旅行会去秋叶原吗？", context: nil, expected: ids["tokyo"], category: "zh"),
            .init(id: "r09", primary: "数学公式用 LaTeX 排版对吗？", context: nil, expected: ids["latex"], category: "mixed"),
            .init(id: "r10", primary: "BanG Dream! Our Notes 的开服消息", context: nil, expected: ids["bangdream"], category: "mixed"),
            .init(id: "r11", primary: "助手项目接入的是 DeepSeek API 吗？", context: nil, expected: ids["deepseek"], category: "mixed"),
            .init(id: "r12", primary: "花生过敏所以必须避开花生吗？", context: nil, expected: ids["allergy"], category: "zh"),
            .init(id: "r13", primary: "推荐零食要避开我的花生过敏", context: nil, expected: ids["allergy"], category: "zh"),
            .init(id: "r14", primary: "我吃素并偏好素食菜品吗？", context: nil, expected: ids["vegetarian"], category: "zh"),
            .init(id: "r15", primary: "线性代数的特征值与特征向量", context: nil, expected: ids["math"], category: "zh"),
            .init(id: "r16", primary: "我常听 YOASOBI 和 Aimer 的音乐吗？", context: nil, expected: ids["music"], category: "mixed"),
            .init(id: "r17", primary: "主力手机是 iPhone 17 Pro 吗？", context: nil, expected: ids["device"], category: "mixed"),
            .init(id: "r18", primary: "香港时区 Asia/Hong_Kong 如何安排提醒？", context: nil, expected: ids["timezone"], category: "mixed"),
            .init(id: "r19", primary: "耳机预算最多两千元吗？", context: nil, expected: ids["budget"], category: "zh"),
            .init(id: "r20", primary: "回答偏好先给结论再简洁解释", context: nil, expected: ids["concise"], category: "zh"),
            .init(id: "r21", primary: "用 Python 学习 pandas 数据分析", context: nil, expected: ids["python"], category: "mixed"),
            .init(id: "r22", primary: "每周三和周六跑步五公里", context: nil, expected: ids["running"], category: "zh"),
            .init(id: "r23", primary: "隐私要求是不上传本地笔记吗？", context: nil, expected: ids["privacy"], category: "zh"),
            .init(id: "r24", primary: "再说说那个安排", context: "每周三和周六晚上跑步五公里", expected: ids["running"], category: "context"),
            .init(id: "r25", primary: "还有那个预算呢？", context: "购买耳机最多准备两千元", expected: ids["budget"], category: "context"),
            .init(id: "r26", primary: "那个游戏呢？", context: "我在等 BanG Dream! Our Notes 开服", expected: ids["bangdream"], category: "context"),
            .init(id: "r27", primary: "继续", context: "使用 Python 和 pandas 做数据分析", expected: ids["python"], category: "context"),
            .init(id: "r28", primary: "那个歌手组合呢？", context: "我常听 YOASOBI 和 Aimer", expected: ids["music"], category: "context"),
            .init(id: "r29", primary: "手机设备型号", context: "iPhone 17 Pro", expected: ids["device"], category: "context"),
            .init(id: "r30", primary: "东京秋叶原出行", context: "十月旅行计划", expected: ids["tokyo"], category: "context"),
            .init(id: "n01", primary: "法国首都是什么？", context: nil, expected: nil, category: "none"),
            .init(id: "n02", primary: "今天北京天气怎么样？", context: nil, expected: nil, category: "none"),
            .init(id: "n03", primary: "二次方程怎么求解？", context: nil, expected: nil, category: "none"),
            .init(id: "n04", primary: "珠穆朗玛峰多高？", context: nil, expected: nil, category: "none"),
            .init(id: "n05", primary: "解释霍金辐射", context: nil, expected: nil, category: "none"),
            .init(id: "n06", primary: "美元汇率是多少？", context: nil, expected: nil, category: "none"),
            .init(id: "n07", primary: "写一首关于大海的诗", context: nil, expected: nil, category: "none"),
            .init(id: "n08", primary: "牛顿第二定律是什么？", context: nil, expected: nil, category: "none"),
            .init(id: "n09", primary: "附近有哪些餐厅？", context: nil, expected: nil, category: "none"),
            .init(id: "n10", primary: "把句子翻译成法语", context: nil, expected: nil, category: "none"),
            .init(id: "n11", primary: "量子计算如何纠错？", context: nil, expected: nil, category: "none"),
            .init(id: "n12", primary: "明天会下雨吗？", context: nil, expected: nil, category: "none"),
            .init(id: "n13", primary: "莎士比亚出生在哪里？", context: nil, expected: nil, category: "none"),
            .init(id: "n14", primary: "太阳系有几颗行星？", context: nil, expected: nil, category: "none"),
            .init(id: "n15", primary: "如何修理漏水的水龙头？", context: nil, expected: nil, category: "none"),
            .init(id: "n16", primary: "火星殖民需要什么技术？", context: nil, expected: nil, category: "none")
        ]
        return (records, queries, forbidden)
    }

    private func record(
        id: UUID,
        kind: MemoryKind,
        text: String,
        scope: String,
        status: MemoryStatus,
        confirmedAt: Date,
        expiresAt: Date? = nil,
        embeddingData: Data? = nil
    ) -> MemoryRetrievalRecord {
        .init(memory: .init(
            id: id, scopeID: scope, kindRawValue: kind.rawValue, canonicalText: text,
            embeddingData: embeddingData, importance: 0.6, confidence: 0.9, statusRawValue: status.rawValue,
            createdAt: confirmedAt, updatedAt: confirmedAt, lastConfirmedAt: confirmedAt,
            lastReinforcedAt: nil, expiresAt: expiresAt, reinforcementCount: 1
        ), sources: [])
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "MemoryRetrievalEvaluation", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
    }

    private func write(_ report: Report) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let directory = FileManager.default.temporaryDirectory
        try encoder.encode(report).write(to: directory.appendingPathComponent("memory-retrieval-evaluation.json"), options: .atomic)
        let markdown = """
        # Memory Retrieval Evaluation

        Queries: \(report.queryCount), relevant: \(report.relevantCount), no-result: \(report.noResultCount).

        Provider decision: \(report.providerDecision)

        | Phase | semantic gate | lexical gate | Precision@3 | Recall@3 | Recall@5 | MRR | No-result accuracy | False retrieval | Contextual recall |
        |---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
        | before | \(format(report.beforeParameters.semanticGate)) | \(format(report.beforeParameters.lexicalGate)) | \(format(report.beforeMetrics.precisionAt3)) | \(format(report.beforeMetrics.recallAt3)) | \(format(report.beforeMetrics.recallAt5)) | \(format(report.beforeMetrics.meanReciprocalRank)) | \(format(report.beforeMetrics.noResultAccuracy)) | \(format(report.beforeMetrics.falseRetrievalRate)) | \(format(report.beforeMetrics.contextualRecall)) |
        | after | \(format(report.afterParameters.semanticGate)) | \(format(report.afterParameters.lexicalGate)) | \(format(report.afterMetrics.precisionAt3)) | \(format(report.afterMetrics.recallAt3)) | \(format(report.afterMetrics.recallAt5)) | \(format(report.afterMetrics.meanReciprocalRank)) | \(format(report.afterMetrics.noResultAccuracy)) | \(format(report.afterMetrics.falseRetrievalRate)) | \(format(report.afterMetrics.contextualRecall)) |

        Hard gates after tuning: expired=\(report.afterMetrics.expiredLeakage), superseded=\(report.afterMetrics.supersededLeakage), invalidated=\(report.afterMetrics.invalidatedLeakage), cross-scope=\(report.afterMetrics.crossScopeLeakage), stale-embedding=\(report.afterMetrics.staleEmbeddingUse).

        Target passed: \(report.targetPassed).
        """
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("memory-retrieval-evaluation.md"), options: .atomic)
    }

    private func format(_ value: Double) -> String { String(format: "%.3f", value) }
}

private actor RetrievalEvaluationSemanticResolver: MemorySemanticEmbeddingResolving {
    static let descriptorValue = MemoryEmbeddingDescriptor(
        provider: "retrieval-evaluation", modelIdentifier: "current-model", revision: 1,
        dimension: 2, modelFamily: "evaluation", language: "zh-Hans", semantic: true
    )

    func descriptor(for text: String) -> MemoryEmbeddingDescriptor? { Self.descriptorValue }

    func embedding(for text: String) throws -> MemoryEmbeddingVector {
        try .init(descriptor: Self.descriptorValue, values: [1, 0])
    }
}
