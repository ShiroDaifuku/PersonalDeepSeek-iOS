import XCTest
@testable import PersonalDeepSeek

final class AssistantToolTests: XCTestCase {
    func testDecodesKnowledgeToolAndClampsLimit() throws {
        let call = try AssistantToolPlanner.decode(name: "search_local_knowledge", arguments: #"{"query":"合同期限","limit":99}"#)
        XCTAssertEqual(call, .searchKnowledge(query: "合同期限", limit: 10))
    }

    func testDecodesStrictTaskDraft() throws {
        let json = #"{"title":"晨间摘要","kind":"recurring","schedule":{"type":"cron","expression":"0 9 * * *","timezone":"Asia/Hong_Kong"},"prompt":"总结昨日笔记","tools":["none"],"notify":true}"#
        let call = try AssistantToolPlanner.decode(name: "create_scheduled_task", arguments: json)
        guard case .createTask(let draft) = call else { return XCTFail("Expected task draft") }
        XCTAssertEqual(draft.schedule.timezone, "Asia/Hong_Kong")
        XCTAssertTrue(draft.notify)
    }

    func testRejectsIncompleteEditArguments() {
        XCTAssertThrowsError(try AssistantToolPlanner.decode(name: "edit_scheduled_task", arguments: #"{"task_id":"x"}"#))
    }
}
