import XCTest
@testable import PersonalDeepSeek

final class AlarmScheduleParserTests: XCTestCase {
    func testParsesDailyCronAsEveryWeekday() {
        let value = AlarmScheduleParser.parse(taskID: UUID().uuidString, title: "日报", schedule: .init(type: "cron", expression: "30 9 * * *", timezone: "Asia/Hong_Kong"))
        XCTAssertEqual(value?.hour, 9)
        XCTAssertEqual(value?.minute, 30)
        XCTAssertEqual(value?.weekdays, Array(1...7))
    }

    func testRejectsCronWithoutConcreteTime() {
        XCTAssertNil(AlarmScheduleParser.parse(taskID: UUID().uuidString, title: "错误", schedule: .init(type: "cron", expression: "* 9 * * *", timezone: "UTC")))
    }

    func testParsesOneShotAsFixedDate() {
        let value = AlarmScheduleParser.parse(taskID: UUID().uuidString, title: "一次", schedule: .init(type: "once", expression: "2099-01-01T00:00:00Z", timezone: "UTC"))
        XCTAssertNotNil(value?.fixedDate)
        XCTAssertEqual(value?.weekdays, [])
    }
}
