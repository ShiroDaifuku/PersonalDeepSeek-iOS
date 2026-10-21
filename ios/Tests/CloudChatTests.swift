import XCTest
@testable import PersonalDeepSeek

final class CloudChatTests: XCTestCase {
    private func ticket() -> CloudChatTicket {
        let id = UUID()
        return .init(id: id, conversationID: UUID(), userMessageID: UUID(), assistantMessageID: id,
            userText: "公开测试问题", ownerID: "personal-test-owner", baseURL: "https://example.com", createdAt: Date())
    }
    private func request() -> AgentModelRequest {
        .init(messages: [.init(role: "system", content: "stable system"), .init(role: "user", content: "公开测试问题")],
            model: DeepSeekModelCompatibility.flash, thinking: true, reasoningEffort: "high", toolNames: [], toolChoice: .auto)
    }
    func testPreparedRequestKeepsExactPrefixAndNeverIncludesKeychainCredential() throws {
        let t = ticket(), r = request()
        let frozen = try CloudChatModel.prepared(t, request: r)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: frozen.requestData!) as? [String: Any])
        let body = try XCTUnwrap(root["request"] as? [String: Any])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: APIClient.requestBody(r)) as? NSDictionary)
        XCTAssertEqual(body as NSDictionary, original)
        XCTAssertEqual(root["id"] as? String, t.assistantMessageID.uuidString)
        XCTAssertNil(root["api_key"]); XCTAssertNil(body["api_key"]); XCTAssertNil(body["Authorization"])
        XCTAssertEqual(try CloudChatModel.prepared(t, request: r).requestData, frozen.requestData)
    }
    func testLocalToolsAndImagesCannotSilentlyBecomeToolFreeCloudChat() throws {
        let t = ticket()
        var tools = request()
        // AgentModelRequest fields are immutable: construct the unsupported variant explicitly.
        tools = .init(messages: tools.messages, model: tools.model, thinking: tools.thinking,
            reasoningEffort: tools.reasoningEffort, toolNames: ["web_search"], toolChoice: .auto)
        XCTAssertThrowsError(try CloudChatModel.prepared(t, request: tools))
        let image = AgentModelRequest(messages: [.init(role: "user", content: "image", imageDataURLs: ["data:image/jpeg;base64,test"])],
            model: DeepSeekModelCompatibility.flash, thinking: false, reasoningEffort: "low", toolNames: [], toolChoice: .auto)
        XCTAssertThrowsError(try CloudChatModel.prepared(t, request: image))
    }
    func testOutboxReloadAndStopBeforeInsertRaceAreDurable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-outbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = CloudChatOutbox(directory: root)
        let t = try CloudChatModel.prepared(ticket(), request: request())
        try await first.requestCancellation(t.id)
        try await first.put(t)
        let reopened = CloudChatOutbox(directory: root)
        let records = try await reopened.all()
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].cancelRequested)
        XCTAssertEqual(records[0].requestData, t.requestData)
        XCTAssertEqual(records[0].conversationID, t.conversationID)
        try await reopened.remove(t.id)
        let remaining = try await first.all(); XCTAssertTrue(remaining.isEmpty)
    }
    func testOutboxConcurrentWritesRemainIdentifierScopedAndConflictSafe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-concurrency-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let box = CloudChatOutbox(directory: root)
        let values = try (0..<20).map { _ in try CloudChatModel.prepared(ticket(), request: request()) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in values { group.addTask { try await box.put(value) } }
            try await group.waitForAll()
        }
        let saved = try await box.all(); XCTAssertEqual(saved.count, 20)
        let extra = try CloudChatModel.prepared(ticket(), request: request())
        do { try await box.put(extra); XCTFail("Unbounded outbox admitted") } catch { }
        var changed = values[0]; changed.requestData = Data("different frozen request".utf8)
        do { try await box.put(changed); XCTFail("Request overwrite accepted") } catch { }
        let after = try await box.all()
        XCTAssertEqual(after.first(where: { $0.id == values[0].id })?.requestData, values[0].requestData)
    }
    func testResponseIdentityCompletionAndOutputLimitsAreValidated() throws {
        let t = ticket()
        func snapshot(_ id: UUID, _ status: String, _ content: String) -> CloudChatSnapshot {
            .init(id: id, conversationID: t.conversationID, userMessageID: t.userMessageID,
                assistantMessageID: t.assistantMessageID, status: status, content: content, reasoning: "",
                errorCode: nil, expiresAt: Date().timeIntervalSince1970 * 1000 + 60000)
        }
        XCTAssertNoThrow(try snapshot(t.id,"succeeded","answer").validate(for:t))
        XCTAssertThrowsError(try snapshot(UUID(),"succeeded","answer").validate(for:t))
        XCTAssertThrowsError(try snapshot(t.id,"succeeded","").validate(for:t))
        XCTAssertThrowsError(try snapshot(t.id,"succeeded",String(repeating:"x",count:200001)).validate(for:t))
        XCTAssertThrowsError(try snapshot(t.id,"unknown","answer").validate(for:t))
        XCTAssertFalse(snapshot(t.id,"running","partial").terminal)
    }
}
