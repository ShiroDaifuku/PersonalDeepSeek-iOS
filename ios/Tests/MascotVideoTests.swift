import XCTest
@testable import PersonalDeepSeek

final class MascotVideoTests: XCTestCase {
    func testModesUseStableDistinctResourceNames() {
        XCTAssertEqual(MascotVideoMode.idle.resourceName, "MascotIdle")
        XCTAssertEqual(MascotVideoMode.thinking.resourceName, "MascotThinking")
        XCTAssertNotEqual(MascotVideoMode.idle.resourceName, MascotVideoMode.thinking.resourceName)
    }
}
