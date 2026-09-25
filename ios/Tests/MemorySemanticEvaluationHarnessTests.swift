#if DEBUG
import XCTest
@testable import PersonalDeepSeek

final class MemorySemanticEvaluationHarnessTests: XCTestCase {
    func testBenchmarkHasRequiredScaleAndNegativeCoverage() {
        let summary = MemorySemanticEvaluationTestHooks.benchmarkSummary
        XCTAssertGreaterThanOrEqual(summary.queries, 40)
        XCTAssertGreaterThanOrEqual(summary.relevant, 20)
        XCTAssertGreaterThanOrEqual(summary.noResult, 10)
        XCTAssertGreaterThanOrEqual(summary.lowOverlap, 20)
        XCTAssertEqual(summary.queries, summary.relevant + summary.noResult)
    }

    func testPhysicalDeviceEvaluatorRejectsSimulator() async {
        #if targetEnvironment(simulator)
        do {
            _ = try await MemorySemanticPhysicalDeviceEvaluator().run(requestContextualAssets: false)
            XCTFail("Simulator must not produce a physical-device report")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("真实 iPhone"))
        }
        #endif
    }
}
#endif
