import XCTest
@testable import PersonalDeepSeek

final class AssistantToolTests: XCTestCase {
    func testRoutesExplicitSchedulesBeforeKnowledgeWords() {
        XCTAssertEqual(AssistantIntentRouter.preferredTool(for: "每天上午九点总结我的笔记"), "create_scheduled_task")
        XCTAssertEqual(AssistantIntentRouter.preferredTool(for: "把任务改成每天十点"), "edit_scheduled_task")
    }

    func testRoutesResearchAndKnowledge() {
        XCTAssertEqual(AssistantIntentRouter.preferredTool(for: "深度研究一下新能源政策"), "start_deep_search")
        XCTAssertEqual(AssistantIntentRouter.preferredTool(for: "从我的笔记里找合同期限"), "search_local_knowledge")
        XCTAssertNil(AssistantIntentRouter.preferredTool(for: "解释一下什么是递归"))
    }

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
