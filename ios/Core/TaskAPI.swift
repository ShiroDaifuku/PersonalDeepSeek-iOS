import Foundation

struct TaskSchedule: Codable, Equatable, Sendable { var type: String; var expression: String; var timezone: String }
struct TaskDraft: Codable, Equatable, Sendable {
    var title: String
    var kind: String
    var schedule: TaskSchedule
    var prompt: String
    var tools: [String]
    var notify: Bool
    var knowledgeBaseIDs: [String] = []

    enum CodingKeys: String, CodingKey { case title, kind, schedule, prompt, tools, notify; case knowledgeBaseIDs = "knowledge_base_ids" }
    init(title: String, kind: String, schedule: TaskSchedule, prompt: String, tools: [String], notify: Bool, knowledgeBaseIDs: [String] = []) {
        self.title = title; self.kind = kind; self.schedule = schedule; self.prompt = prompt; self.tools = tools; self.notify = notify; self.knowledgeBaseIDs = knowledgeBaseIDs
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title); kind = try values.decode(String.self, forKey: .kind)
        schedule = try values.decode(TaskSchedule.self, forKey: .schedule); prompt = try values.decode(String.self, forKey: .prompt)
        tools = try values.decode([String].self, forKey: .tools); notify = try values.decode(Bool.self, forKey: .notify)
        knowledgeBaseIDs = try values.decodeIfPresent([String].self, forKey: .knowledgeBaseIDs) ?? []
    }
}
struct RemoteTask: Codable, Identifiable, Equatable, Sendable {
    var id: String; var title: String; var kind: String; var schedule: TaskSchedule; var prompt: String; var tools: [String]; var notify: Bool; var knowledgeBaseIDs: [String]?
    var enabled: Bool; var nextRunAt: String?
    enum CodingKeys: String, CodingKey { case id, title, kind, schedule, prompt, tools, notify, enabled, nextRunAt; case knowledgeBaseIDs = "knowledge_base_ids" }
}
struct RemoteTaskRun: Codable, Identifiable, Equatable {
    var id: String; var taskId: String; var startedAt: String; var completedAt: String
    var status: String; var model: String; var output: String?; var error: String?
    var promptTokens: Int; var completionTokens: Int; var costMicros: Int; var read: Bool
    var notificationStatus: String?
}
private struct DraftEnvelope: Codable { let draft: TaskDraft }
private struct TaskEnvelope: Codable { let task: RemoteTask }
private struct TasksEnvelope: Codable { let tasks: [RemoteTask] }
private struct RunsEnvelope: Codable { let runs: [RemoteTaskRun] }
struct APIErrorEnvelope: Codable { struct Body: Codable { let code: String; let message: String; let retryable: Bool }; let error: Body }

final class TaskAPI: Sendable {
    let base: URL; let userID: String
    init(base: URL, userID: String) { self.base = base; self.userID = userID }
    func parse(_ text: String) async throws -> TaskDraft { try await call("v1/tasks/parse", method: "POST", body: ["text": text], as: DraftEnvelope.self).draft }
    func create(_ draft: TaskDraft) async throws -> RemoteTask { try await call("v1/tasks", method: "POST", encodable: draft, as: TaskEnvelope.self).task }
    func update(_ task: RemoteTask, draft: TaskDraft, enabled: Bool) async throws -> RemoteTask {
        struct Update: Encodable { let title: String; let kind: String; let schedule: TaskSchedule; let prompt: String; let tools: [String]; let notify: Bool; let enabled: Bool; let knowledgeBaseIDs: [String]; enum CodingKeys: String, CodingKey { case title, kind, schedule, prompt, tools, notify, enabled; case knowledgeBaseIDs = "knowledge_base_ids" } }
        let value = Update(title: draft.title, kind: draft.kind, schedule: draft.schedule, prompt: draft.prompt, tools: draft.tools, notify: draft.notify, enabled: enabled, knowledgeBaseIDs: draft.knowledgeBaseIDs)
        return try await call("v1/tasks/\(task.id)", method: "PATCH", encodable: value, as: TaskEnvelope.self).task
    }
    func list() async throws -> [RemoteTask] { try await call("v1/tasks", method: "GET", as: TasksEnvelope.self).tasks }
    func setEnabled(_ task: RemoteTask, _ enabled: Bool) async throws -> RemoteTask { try await call("v1/tasks/\(task.id)", method: "PATCH", body: ["enabled": enabled], as: TaskEnvelope.self).task }
    func delete(_ task: RemoteTask) async throws { _ = try await request("v1/tasks/\(task.id)", method: "DELETE", data: nil) }
    func runs(_ task: RemoteTask) async throws -> [RemoteTaskRun] { try await call("v1/tasks/\(task.id)/runs", method: "GET", as: RunsEnvelope.self).runs }
    func markRead(taskID: String, runID: String) async throws { _ = try await request("v1/tasks/\(taskID)/runs/\(runID)", method: "PATCH", data: try JSONSerialization.data(withJSONObject: ["read": true])) }
    private func call<T: Decodable>(_ path: String, method: String, body: [String: Any]? = nil, as type: T.Type) async throws -> T {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try decode(try await request(path, method: method, data: data), as: type)
    }
    private func call<T: Decodable, E: Encodable>(_ path: String, method: String, encodable: E, as type: T.Type) async throws -> T {
        let data = try JSONEncoder().encode(encodable)
        return try decode(try await request(path, method: method, data: data), as: type)
    }
    private func decode<T: Decodable>(_ response: (Data, URLResponse), as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: response.0)
    }
    private func request(_ path: String, method: String, data: Data?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: base.appending(path: path)); request.httpMethod = method; request.setValue(userID, forHTTPHeaderField: "X-User-ID"); request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = data
        if let token = KeychainStore.readCloudServiceToken(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let result = try await URLSession.shared.data(for: request); if let response = result.1 as? HTTPURLResponse, !(200..<300).contains(response.statusCode) { if let body = try? JSONDecoder().decode(APIErrorEnvelope.self, from: result.0) { throw NSError(domain: body.error.code, code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: body.error.message]) }; throw ClientError.badResponse(response.statusCode) }; return result
    }
}

struct CloudKnowledgeBasePayload: Codable, Sendable {
    struct Chunk: Codable, Sendable { let id: String; let documentName: String; let index: Int; let text: String; enum CodingKeys: String, CodingKey { case id, index, text; case documentName = "document_name" } }
    let id: String; let name: String; let enabled: Bool; let chunks: [Chunk]
}

final class KnowledgeSyncAPI: Sendable {
    private let taskAPI: TaskAPI
    init(base: URL, userID: String) { taskAPI = TaskAPI(base: base, userID: userID) }
    func replaceAll(_ bases: [CloudKnowledgeBasePayload]) async throws {
        struct Body: Encodable { let knowledgeBases: [CloudKnowledgeBasePayload]; enum CodingKeys: String, CodingKey { case knowledgeBases = "knowledge_bases" } }
        _ = try await taskAPI.send("v1/knowledge/sync", method: "PUT", encodable: Body(knowledgeBases: bases))
    }
}

extension TaskAPI {
    fileprivate func send<E: Encodable>(_ path: String, method: String, encodable: E) async throws -> (Data, URLResponse) {
        try await request(path, method: method, data: JSONEncoder().encode(encodable))
    }
}
