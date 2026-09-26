import Foundation

enum MemoryQueryIntent: String, Codable, Sendable, CaseIterable {
    case recommendation
    case personalChoice
    case personalTroubleshooting
    case projectContinuity
    case learningContinuity
    case followUp
    case generalFact
    case generalExplanation
    case other
}

enum MemoryCandidateRejectionReason: String, Codable, Sendable, Equatable, Hashable {
    case belowAbsoluteSemantic = "below_absolute_semantic"
    case insufficientMargin = "insufficient_margin"
    case insufficientDistributionGap = "insufficient_distribution_gap"
    case intentKindIncompatible = "intent_kind_incompatible"
    case notTopSemanticCandidate = "not_top_semantic_candidate"
    case belowLexicalGate = "below_lexical_gate"
    case resultLimit = "result_limit"
    case expired
    case wrongScope = "wrong_scope"
    case superseded
    case invalidated
    case staleEmbedding = "stale_embedding"
    case currentConversationOnly = "current_conversation_only"
    case emptyText = "empty_text"
}

struct MemorySemanticConfidenceConfiguration: Codable, Sendable, Equatable {
    var minimumAbsoluteSemantic: Double
    var minimumTopMargin: Double
    var minimumMedianGap: Double
    var minimumRobustZ: Double
    var epsilon: Double

    init(
        minimumAbsoluteSemantic: Double = 0.78,
        minimumTopMargin: Double = 0.055,
        minimumMedianGap: Double = 0.10,
        minimumRobustZ: Double = 3.0,
        epsilon: Double = 0.000_001
    ) {
        self.minimumAbsoluteSemantic = minimumAbsoluteSemantic
        self.minimumTopMargin = minimumTopMargin
        self.minimumMedianGap = minimumMedianGap
        self.minimumRobustZ = minimumRobustZ
        self.epsilon = max(epsilon, 0.000_000_001)
    }
}

struct MemorySemanticQueryStatistics: Codable, Sendable, Equatable {
    let top1Score: Double
    let top2Score: Double
    let top1Top2Margin: Double
    let medianScore: Double
    let top1MedianGap: Double
    let medianAbsoluteDeviation: Double
    let robustZ: Double

    static func make(scores: [Double], epsilon: Double) -> Self? {
        let values = scores.filter(\.isFinite).sorted(by: >)
        guard let top1 = values.first else { return nil }
        let top2 = values.dropFirst().first ?? top1
        let median = Self.median(values)
        let mad = Self.median(values.map { abs($0 - median) })
        return .init(
            top1Score: top1,
            top2Score: top2,
            top1Top2Margin: top1 - top2,
            medianScore: median,
            top1MedianGap: top1 - median,
            medianAbsoluteDeviation: mad,
            robustZ: (top1 - median) / max(mad, epsilon)
        )
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) { return (sorted[middle - 1] + sorted[middle]) / 2 }
        return sorted[middle]
    }
}

struct MemoryUsefulnessDecision: Codable, Sendable, Equatable {
    let intent: MemoryQueryIntent
    let kindCompatible: Bool
    let eventContinuityBypass: Bool
}

enum MemoryQueryIntentClassifier {
    static func classify(_ text: String) -> MemoryQueryIntent {
        let value = MemoryEmbeddingText.normalized(text)
        if contains(value, ["继续", "上次", "之前", "先前", "原先", "刚才", "那个问题", "接着", "延续", "已有", "现有", "follow up", "continue"]) { return .followUp }
        if contains(value, ["推荐", "介绍几", "给我挑", "我会喜欢", "适合我", "recommend", "suggest"]) { return .recommendation }
        if contains(value, ["我这个项目", "我的项目", "这个项目", "当前项目", "现在这个 app", "这个 app", "手机端 ai 助手", "客户端", "下一步", "继续实现", "怎么设计", "跨会话", "project"]) { return .projectContinuity }
        if contains(value, ["我的电脑", "我电脑", "我手机", "我的设备", "独显", "黑屏", "闪屏", "报错", "故障", "排查", "troubleshoot"]) { return .personalTroubleshooting }
        if contains(value, ["第14题", "第 14 题", "知识点", "仍不能", "还是不能", "换基", "谱完全", "特征根", "矩阵", "先前讨论", "学习进度", "最近学", "最近复习", "复习内容"]) { return .learningContinuity }
        if contains(value, ["选哪个", "怎么选", "买哪个", "是否适合", "能不能吃", "我能不能", "我可以", "我该", "比较一下", "对我", "预算", "我家", "我的猫", "我的宠物", "我的饮食", "我的时区", "我的周期", "我常用", "按我", "根据我", "符合我", "我适合", "我会", "我的习惯", "我的偏好", "我的", "choice"]) { return .personalChoice }
        if contains(value, ["谁", "哪年", "什么时候", "发布日期", "上映日期", "票房", "导演", "最新专辑", "叫什么", "多少", "where", "when", "who"]) { return .generalFact }
        if contains(value, ["为什么", "是什么", "怎么证明", "原理", "解释", "如何实现", "how", "why", "what is"]) { return .generalExplanation }
        return .other
    }

    private static func contains(_ text: String, _ terms: [String]) -> Bool {
        terms.contains(where: text.contains)
    }
}

enum MemoryUsefulnessGate {
    static func evaluate(
        kind: MemoryKind,
        query: String,
        statistics: MemorySemanticQueryStatistics?,
        configuration: MemorySemanticConfidenceConfiguration
    ) -> MemoryUsefulnessDecision {
        let intent = MemoryQueryIntentClassifier.classify(query)
        let compatible: Bool
        switch kind {
        case .preference:
            compatible = [.recommendation, .personalChoice, .followUp].contains(intent)
        case .durableFact:
            compatible = [.recommendation, .personalChoice, .personalTroubleshooting, .followUp].contains(intent)
        case .ongoingContext:
            compatible = [.projectContinuity, .personalTroubleshooting, .followUp].contains(intent)
        case .recentState:
            compatible = [.learningContinuity, .followUp, .personalChoice].contains(intent)
        case .event:
            compatible = [.learningContinuity, .followUp].contains(intent)
        case .other:
            compatible = intent == .followUp
        }
        let eventBypass = kind == .event && statistics.map {
            $0.top1Score >= max(0.90, configuration.minimumAbsoluteSemantic) &&
            ($0.top1Top2Margin >= configuration.minimumTopMargin ||
             $0.top1MedianGap >= configuration.minimumMedianGap ||
             $0.robustZ >= configuration.minimumRobustZ)
        } ?? false
        return .init(intent: intent, kindCompatible: compatible || eventBypass, eventContinuityBypass: eventBypass)
    }
}

struct MemoryCandidateEvaluation: Codable, Sendable, Equatable, Identifiable {
    var id: UUID { memoryID }
    let memoryID: UUID
    let kind: MemoryKind
    let semanticScore: Double?
    let lexicalScore: Double
    let entityMatch: Bool
    let semanticStatistics: MemorySemanticQueryStatistics?
    let queryIntent: MemoryQueryIntent
    let kindCompatible: Bool
    let acceptedByLexicalPath: Bool
    let acceptedBySemanticPath: Bool
    let accepted: Bool
    let rejectionReasons: [MemoryCandidateRejectionReason]
}
