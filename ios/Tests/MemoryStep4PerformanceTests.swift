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
                ? "用户偏好深色模式、简洁布局和结论先行的回答。"
                : "用户的合成测试偏好编号 \(index)，用于构造固定规模的本地候选集合。"
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
        let pipeline = MemoryChatReadPipeline(
            retriever: MemoryRetriever(store: store, semanticResolver: nil),
            configuration: .init(deadlineMilliseconds: 180, budget: .chatDefault)
        )
        let input = MemoryRetrievalInput(primaryText: "请用我偏好的深色简洁界面风格给出建议。")
        var retrieval: [Int] = []
        var builds: [Int] = []
        for _ in 0..<100 {
            let outcome = await pipeline.read(
                input: input,
                currentUserText: "请用我偏好的深色简洁界面风格给出建议。",
                now: now
            )
            XCTAssertEqual(outcome.status, .injected)
            retrieval.append(outcome.retrievalMilliseconds)
            builds.append(outcome.contextBuildMilliseconds)
        }
        retrieval.sort()
        builds.sort()
        let retrievalP50 = percentile(retrieval, 0.50)
        let retrievalP95 = percentile(retrieval, 0.95)
        let buildP50 = percentile(builds, 0.50)
        let buildP95 = percentile(builds, 0.95)
        print(
            "STEP4_PERFORMANCE retrieval_p50_ms=\(retrievalP50) retrieval_p95_ms=\(retrievalP95) " +
            "context_build_p50_ms=\(buildP50) context_build_p95_ms=\(buildP95) iterations=100 candidates=48"
        )
        XCTAssertLessThanOrEqual(retrievalP95, 100)
        XCTAssertLessThanOrEqual(buildP95, 20)
    }

    private func percentile(_ values: [Int], _ percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let index = Int((Double(values.count - 1) * percentile).rounded(.up))
        return values[min(index, values.count - 1)]
    }
}
