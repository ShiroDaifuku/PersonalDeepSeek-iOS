import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

@MainActor
final class MemoryStep4PerformanceTests: XCTestCase {
    func testWarmLocalRetrievalAndContextBuildP95() async throws {
        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        let configuration = ModelConfiguration(
            "MemoryStep4Performance",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = MemoryStore(modelContainer: container)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        for index in 0..<48 {
            let text = index == 0
                ? "用户喜欢深色模式。"
                : "合成候选编号 \(index)，内容主题为城市公共交通样本。"
            _ = try await store.insertMemory(
                scopeID: MemoryScope.localDefault,
                draft: .init(
                    kind: .preference,
                    canonicalText: text,
                    importance: index == 0 ? 0.9 : 0.4,
                    createdAt: now,
                    updatedAt: now,
                    lastConfirmedAt: now
                )
            )
        }
        let retriever = MemoryRetriever(store: store, semanticResolver: nil)
        let input = MemoryRetrievalInput(primaryText: "我偏好什么界面模式？")
        var retrieval: [Int] = []
        var builds: [Int] = []
        for _ in 0..<50 {
            let retrievalStart = ContinuousClock.now
            let results = try await retriever.search(input, now: now)
            retrieval.append(milliseconds(retrievalStart.duration(to: .now)))
            XCTAssertEqual(results.first?.canonicalText, "用户喜欢深色模式。")

            let buildStart = ContinuousClock.now
            let context = MemoryContextBuilder.build(
                results: results,
                currentUserText: "我偏好什么界面模式？",
                now: now
            ).context
            builds.append(milliseconds(buildStart.duration(to: .now)))
            XCTAssertNotNil(context)
        }
        retrieval.sort()
        builds.sort()
        let retrievalP50 = percentile(retrieval, 0.50)
        let retrievalP95 = percentile(retrieval, 0.95)
        let buildP50 = percentile(builds, 0.50)
        let buildP95 = percentile(builds, 0.95)
        print(
            "STEP4_PERFORMANCE retrieval_p50_ms=\(retrievalP50) retrieval_p95_ms=\(retrievalP95) " +
            "context_build_p50_ms=\(buildP50) context_build_p95_ms=\(buildP95) iterations=50 candidates=48"
        )
        XCTAssertLessThanOrEqual(retrievalP95, 100)
        XCTAssertLessThanOrEqual(buildP95, 20)
    }

    private func percentile(_ values: [Int], _ percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let index = Int((Double(values.count - 1) * percentile).rounded(.up))
        return values[min(index, values.count - 1)]
    }

    private func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000) +
            Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
