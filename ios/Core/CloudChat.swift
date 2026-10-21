import Foundation

enum CloudChatRouting {
    static func usesCloud(enabled: Bool, preferredTool: String?, attachmentCount: Int, model: String) -> Bool {
        enabled && preferredTool == nil && attachmentCount == 0 &&
        [DeepSeekModelCompatibility.flash, DeepSeekModelCompatibility.pro].contains(DeepSeekModelCompatibility.requestModel(for: model))
    }
}

enum CloudChatError: LocalizedError {
    case invalidConfiguration, unsupported, invalidResponse, remote(String), pendingSave, conflict
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "云端续跑尚未配置，请检查服务地址、访问令牌与服务器 CHAT_USER_ID。"
        case .unsupported: "本请求超过纯文本云端续跑的范围或长度限制。可关闭续跑使用直连；不会删减工具、附件或历史后发送。"
        case .invalidResponse: "云端任务响应无效，已保留本地待恢复记录。"
        case .remote(let code): "云端任务未完成：\(code)。"
        case .pendingSave: "无法保存本地恢复记录，未提交云端任务。"
        case .conflict: "云端任务与原始提问不一致，已停止导入。"
        }
    }
}

struct CloudChatTicket: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let conversationID: UUID
    let userMessageID: UUID
    let assistantMessageID: UUID
    let userText: String
    let ownerID: String
    let baseURL: String
    let createdAt: Date
    var requestData: Data?
    var cancelRequested = false
    var serverCompletedAt: Date?
}

struct CloudChatSnapshot: Decodable, Sendable {
    let id: UUID
    let conversationID: UUID
    let userMessageID: UUID
    let assistantMessageID: UUID
    let status: String
    let content: String
    let reasoning: String
    let errorCode: String?
    let expiresAt: Double
    let completedAt: Double?

    func validate(for ticket: CloudChatTicket) throws {
        guard id == ticket.id, conversationID == ticket.conversationID,
              userMessageID == ticket.userMessageID, assistantMessageID == ticket.assistantMessageID,
              ["queued", "running", "succeeded", "failed", "cancelled"].contains(status),
              content.utf8.count <= 800_000, reasoning.utf8.count <= 2_100_000,
              content.utf16.count + reasoning.utf16.count <= 200_000,
              status != "succeeded" || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudChatError.conflict }
        if status == "succeeded" {
            guard let completedAt, completedAt.isFinite, completedAt > 0, completedAt <= expiresAt else { throw CloudChatError.invalidResponse }
        }
    }
    var terminal: Bool { ["succeeded", "failed", "cancelled"].contains(status) }
    func completedTurn(for ticket: CloudChatTicket, cancelled: Bool, persistenceSucceeded: Bool) throws -> CompletedTurnSnapshot? {
        try validate(for: ticket)
        guard status == "succeeded", !cancelled, let completedAt else { return nil }
        return CompletedTurnEligibility.snapshot(successfulCompletion: true, persistenceSucceeded: persistenceSucceeded,
            conversationID: ticket.conversationID, userMessageID: ticket.userMessageID, userText: ticket.userText,
            assistantMessageID: ticket.assistantMessageID, assistantText: content,
            completedAt: Date(timeIntervalSince1970: completedAt / 1000))
    }
}

/// Protected local outbox, not a chat/Memory model; no SwiftData schema change.
actor CloudChatOutbox {
    static let shared = CloudChatOutbox()
    private let suppliedDirectory: URL?
    init(directory: URL? = nil) { suppliedDirectory = directory }
    private func directory() throws -> URL {
        let url: URL
        if let suppliedDirectory { url = suppliedDirectory }
        else {
            url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("CloudChatOutbox", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func file(_ id: UUID) throws -> URL { try directory().appendingPathComponent("\(id.uuidString).json") }
    private func cancellationFile(_ id: UUID) throws -> URL { try directory().appendingPathComponent("\(id.uuidString).cancel") }
    func all() throws -> [CloudChatTicket] {
        let files = try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "json" }
        guard files.count <= 20 else { throw CloudChatError.invalidResponse }
        return try files.map { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1_500_000 else { throw CloudChatError.invalidResponse }
            let ticket = try JSONDecoder().decode(CloudChatTicket.self, from: Data(contentsOf: url))
            guard ticket.id == id, ticket.assistantMessageID == id else { throw CloudChatError.conflict }
            return ticket
        }.sorted { $0.createdAt < $1.createdAt }
    }
    func put(_ ticket: CloudChatTicket) throws {
        guard ticket.id == ticket.assistantMessageID, (ticket.requestData?.count ?? 0) <= 1_000_000 else { throw CloudChatError.invalidResponse }
        let records = try all()
        let existing = records.first(where: { $0.id == ticket.id })
        guard existing != nil || records.count < 20 else { throw CloudChatError.pendingSave }
        if let old = existing {
            guard old.conversationID == ticket.conversationID, old.userMessageID == ticket.userMessageID,
                  old.requestData == ticket.requestData, old.ownerID == ticket.ownerID, old.baseURL == ticket.baseURL else { throw CloudChatError.conflict }
        }
        var stored = ticket
        if FileManager.default.fileExists(atPath: try cancellationFile(ticket.id).path) { stored.cancelRequested = true }
        let data = try JSONEncoder().encode(stored)
        guard data.count <= 1_500_000 else { throw CloudChatError.pendingSave }
        try data.write(to: file(ticket.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func requestCancellation(_ id: UUID) throws {
        // A durable tombstone also covers Stop racing the initial outbox insertion.
        try Data().write(to: cancellationFile(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard var ticket = try all().first(where: { $0.id == id }) else { return }
        ticket.cancelRequested = true; try put(ticket)
    }
    func remove(_ id: UUID) throws {
        let url = try file(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let cancellation = try cancellationFile(id)
        if FileManager.default.fileExists(atPath: cancellation.path) { try FileManager.default.removeItem(at: cancellation) }
    }
}

struct CloudChatAPI: Sendable {
    let ticket: CloudChatTicket
    var session: URLSession = .shared
    var tokenProvider: @Sendable () -> String? = { KeychainStore.readCloudServiceToken() }

    func call(_ method: String, submit: Bool = false) async throws -> CloudChatSnapshot {
        guard let base = URL(string: ticket.baseURL), base.scheme == "https", base.user == nil, base.password == nil,
              let token = tokenProvider(), !token.isEmpty, !ticket.ownerID.isEmpty else { throw CloudChatError.invalidConfiguration }
        var request = URLRequest(url: base.appending(path: submit ? "v1/chat-jobs" : "v1/chat-jobs/\(ticket.id.uuidString)"), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(ticket.ownerID, forHTTPHeaderField: "X-User-ID")
        if submit {
            guard let body = ticket.requestData else { throw CloudChatError.invalidResponse }
            request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudChatError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 { throw ClientError.badResponse(404) }
            let code = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.code ?? "http_\(response.statusCode)"
            throw CloudChatError.remote(code)
        }
        guard data.count <= 3_000_000 else { throw CloudChatError.invalidResponse }
        let result = try JSONDecoder().decode(CloudChatSnapshot.self, from: data)
        try result.validate(for: ticket); return result
    }
    func recover() async throws -> CloudChatSnapshot {
        if ticket.cancelRequested {
            do { return try await call("DELETE") }
            catch ClientError.badResponse(404) { throw CloudChatError.remote("cancelled_before_acceptance") }
        }
        do {
            let result = try await call("GET")
            // Repairs a producer failure after the durable row was created but before enqueue acknowledgement.
            if result.status == "queued" { return try await call("POST", submit: true) }
            return result
        }
        catch ClientError.badResponse(404) { return try await call("POST", submit: true) }
    }
}

/// Only used for a single tool-free main-model round. Never substitutes for the native tool executor.
struct CloudChatModel: AgentModelStreaming {
    let ticket: CloudChatTicket
    let outbox: CloudChatOutbox

    static func prepared(_ ticket: CloudChatTicket, request: AgentModelRequest) throws -> CloudChatTicket {
        guard request.toolNames.isEmpty, request.messages.allSatisfy({ $0.imageDataURLs.isEmpty && $0.toolCalls == nil && $0.toolCallID == nil }),
              (1...200).contains(request.messages.count), request.messages.last?.role == "user",
              request.messages.allSatisfy({ ["system", "user", "assistant"].contains($0.role) && $0.reasoningContent == nil }),
              [DeepSeekModelCompatibility.flash, DeepSeekModelCompatibility.pro].contains(DeepSeekModelCompatibility.requestModel(for: request.model)) else { throw CloudChatError.unsupported }
        let wire = try APIClient.requestBody(request)
        guard wire.count <= 900_000 else { throw CloudChatError.unsupported }
        let input = try JSONSerialization.jsonObject(with: wire)
        var value = ticket
        value.requestData = try JSONSerialization.data(withJSONObject: ["id":ticket.id.uuidString,
            "conversationID":ticket.conversationID.uuidString, "userMessageID":ticket.userMessageID.uuidString,
            "assistantMessageID":ticket.assistantMessageID.uuidString, "request":input], options: [.sortedKeys])
        guard value.requestData!.count <= 1_000_000 else { throw CloudChatError.unsupported }
        return value
    }
    func streamRound(_ request: AgentModelRequest) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let frozen = try Self.prepared(ticket, request: request)
                    try await outbox.put(frozen) // Durable locally BEFORE network submission.
                    try Task.checkCancellation()
                    if try await outbox.all().first(where: { $0.id == frozen.id })?.cancelRequested == true { throw CancellationError() }
                    let api = CloudChatAPI(ticket: frozen)
                    var snapshot = try await api.call("POST", submit: true)
                    var contentBytes = 0, reasoningBytes = 0
                    while true {
                        try Task.checkCancellation()
                        if snapshot.status == "cancelled" { throw CancellationError() }
                        if snapshot.status == "failed" { throw CloudChatError.remote(snapshot.errorCode ?? "failed") }
                        guard snapshot.content.utf8.count >= contentBytes, snapshot.reasoning.utf8.count >= reasoningBytes else { throw CloudChatError.invalidResponse }
                        if snapshot.reasoning.utf8.count > reasoningBytes {
                            continuation.yield(.reasoning(String(decoding: snapshot.reasoning.utf8.dropFirst(reasoningBytes), as: UTF8.self)))
                            reasoningBytes = snapshot.reasoning.utf8.count
                        }
                        if snapshot.content.utf8.count > contentBytes {
                            continuation.yield(.content(String(decoding: snapshot.content.utf8.dropFirst(contentBytes), as: UTF8.self)))
                            contentBytes = snapshot.content.utf8.count
                        }
                        if snapshot.status == "succeeded" {
                            var completed = frozen
                            completed.serverCompletedAt = snapshot.completedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
                            try await outbox.put(completed)
                            break
                        }
                        try await Task.sleep(for: .seconds(2))
                        snapshot = try await api.call("GET")
                    }
                    continuation.yield(.finishReason("stop")); continuation.yield(.done); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() } // Disconnect does NOT cancel the server job.
        }
    }
}
