import XCTest
@testable import PersonalDeepSeek

final class MemoryRelevanceCalibrationTests: XCTestCase {
    func testRobustStatisticsUseWholeCandidateDistribution() throws {
        let value = try XCTUnwrap(MemorySemanticQueryStatistics.make(
            scores: [0.96, 0.82, 0.80, 0.78, 0.76], epsilon: 0.000_001
        ))
        XCTAssertEqual(value.top1Score, 0.96, accuracy: 0.000_001)
        XCTAssertEqual(value.top2Score, 0.82, accuracy: 0.000_001)
        XCTAssertEqual(value.top1Top2Margin, 0.14, accuracy: 0.000_001)
        XCTAssertEqual(value.medianScore, 0.80, accuracy: 0.000_001)
        XCTAssertEqual(value.top1MedianGap, 0.16, accuracy: 0.000_001)
        XCTAssertEqual(value.medianAbsoluteDeviation, 0.02, accuracy: 0.000_001)
        XCTAssertEqual(value.robustZ, 8, accuracy: 0.000_001)
    }

    func testIntentClassifierSeparatesPersonalUsefulnessFromFacts() {
        XCTAssertEqual(MemoryQueryIntentClassifier.classify("按我的口味推荐几首歌"), .recommendation)
        XCTAssertEqual(MemoryQueryIntentClassifier.classify("Aimer 最新专辑什么时候发布？"), .generalFact)
        XCTAssertEqual(MemoryQueryIntentClassifier.classify("我这个手机端 AI 助手下一步怎么做？"), .projectContinuity)
        XCTAssertEqual(MemoryQueryIntentClassifier.classify("中心极限定理是什么？"), .generalExplanation)
    }

    func testKindCompatibilityRejectsSameDomainFactualQuestion() {
        let statistics = MemorySemanticQueryStatistics.make(scores: [0.97, 0.81, 0.78], epsilon: 0.000_001)
        let musicFact = MemoryUsefulnessGate.evaluate(
            kind: .preference, query: "Aimer 最新专辑什么时候发布？",
            statistics: statistics, configuration: .init()
        )
        XCTAssertFalse(musicFact.kindCompatible)
        let recommendation = MemoryUsefulnessGate.evaluate(
            kind: .preference, query: "按我的口味推荐几首歌",
            statistics: statistics, configuration: .init()
        )
        XCTAssertTrue(recommendation.kindCompatible)
    }

    func testPersonalContextClassifierCoversUserRelativeFacts() {
        XCTAssertEqual(MemoryQueryIntentClassifier.classify("我的猫需要做年度体检吗？"), .personalChoice)
        XCTAssertEqual(MemoryQueryIntentClassifier.classify("我的宠物猫是什么？"), .personalChoice)
        XCTAssertEqual(MemoryQueryIntentClassifier.classify("我偏好什么界面模式？"), .personalChoice)
        XCTAssertEqual(MemoryQueryIntentClassifier.classify("我常用地区的早上八点创建周期提醒。"), .personalChoice)
        XCTAssertEqual(MemoryQueryIntentClassifier.classify("我的项目下一步怎样实现跨会话状态？"), .projectContinuity)
        XCTAssertEqual(MemoryQueryIntentClassifier.classify("我最近学的科目下一章该看什么？"), .learningContinuity)
    }

    func testUsefulnessRejectsLexicallyExactPreferenceForFactualQuestion() {
        let statistics = MemorySemanticQueryStatistics.make(scores: [0.97, 0.81, 0.78], epsilon: 0.000_001)
        let decision = MemoryUsefulnessGate.evaluate(
            kind: .preference,
            query: "Aimer 最新专辑什么时候发布？",
            statistics: statistics,
            configuration: .init()
        )
        XCTAssertEqual(decision.intent, .generalFact)
        XCTAssertFalse(decision.kindCompatible)
    }

    func testEventContinuityCanUseHighConfidenceDistribution() throws {
        let statistics = try XCTUnwrap(MemorySemanticQueryStatistics.make(
            scores: [0.97, 0.80, 0.78, 0.77], epsilon: 0.000_001
        ))
        let decision = MemoryUsefulnessGate.evaluate(
            kind: .event, query: "两个方阵谱完全相同为什么仍不能保证相似？",
            statistics: statistics, configuration: .init()
        )
        XCTAssertTrue(decision.kindCompatible)
        XCTAssertTrue(decision.eventContinuityBypass)
    }

    func testDevelopmentAndHeldOutSetsMeetScaleAndNegativeRatio() {
        let value = MemorySemanticPrecisionTestHooks.benchmarkSummary
        XCTAssertGreaterThanOrEqual(value.development, 80)
        XCTAssertGreaterThanOrEqual(value.heldOut, 50)
        XCTAssertGreaterThanOrEqual(value.developmentNegatives * 2, value.development)
        XCTAssertGreaterThanOrEqual(value.heldOutNegatives * 2, value.heldOut)
    }
}
