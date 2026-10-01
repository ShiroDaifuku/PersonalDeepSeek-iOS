import Foundation

enum ClientError: LocalizedError, Sendable { case missingKey, badResponse(Int), invalidConfiguration, streamEnded
    var errorDescription: String? { switch self { case .missingKey: "请先在设置中保存 API Key"; case .badResponse(let code): "服务器返回 \(code)"; case .invalidConfiguration: "连接配置无效"; case .streamEnded: "流意外中断，请手动重试" } }
}

final class APIClient: Sendable, AgentModelStreaming {
    private let suppliedKey: String?
    private let session: URLSession
    init(apiKey: String? = nil, session: URLSession = .shared) {
        suppliedKey = apiKey; self.session = session
    }
    func stream(messages: [APIMessage], model: String, thinking: Bool, reasoningEffort: String) -> AsyncThrowingStream<StreamDelta, Error> {
        streamRound(.init(messages: messages, model: model, thinking: thinking,
            reasoningEffort: reasoningEffort, toolNames: [], toolChoice: .auto))
    }

    static func requestBody(_ input: AgentModelRequest) throws -> Data {
        try AgentTranscriptValidator.validate(input.messages)
        var body: [String: Any] = ["model": input.model, "stream": true,
            "messages": input.messages.map(\.wireMessage),
            "thinking": ["type": input.thinking ? "enabled" : "disabled"],
            "reasoning_effort": input.reasoningEffort]
        if !input.toolNames.isEmpty {
            body["tools"] = try ToolRegistry.definitions(names: input.toolNames, strict: input.strict)
            body["tool_choice"] = input.toolChoice.wireValue
            body["stream_options"] = ["include_usage": true]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func streamRound(_ input: AgentModelRequest) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = URL(string: input.strict ? "https://api.deepseek.com/beta/chat/completions" : "https://api.deepseek.com/chat/completions")!
                    guard let key = suppliedKey ?? KeychainStore.readAPIKey(), !key.isEmpty else { throw ClientError.missingKey }
                    let headers = ["Content-Type": "application/json", "X-Request-ID": UUID().uuidString, "Authorization": "Bearer \(key)"]
                    var request = URLRequest(url: endpoint); request.httpMethod = "POST"; headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                    request.httpBody = try Self.requestBody(input); request.timeoutInterval = 610
                    for attempt in 0..<3 {
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidConfiguration }
                        if http.statusCode == 429 || (500...599).contains(http.statusCode), attempt < 2 {
                            let delay = UInt64(Double(500 * (1 << attempt)) * Double.random(in: 0.75...1.25) * 1_000_000)
                            try await Task.sleep(nanoseconds: delay); continue
                        }
                        guard http.statusCode == 200 else { throw ClientError.badResponse(http.statusCode) }
                        var parser = SSEParser(); var emitted = false
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            for event in parser.appendEventLine(line) {
                                if case .content = event { emitted = true }
                                if case .reasoning = event { emitted = true }
                                if case .toolCall = event { emitted = true }
                                if event == .done {
                                    guard emitted else { throw ClientError.streamEnded }
                                    continuation.yield(event); continuation.finish(); return
                                }
                                continuation.yield(event)
                            }
                        }
                        try Task.checkCancellation()
                        for event in parser.finish() {
                            if case .content = event { emitted = true }
                            if case .reasoning = event { emitted = true }
                            if case .toolCall = event { emitted = true }
                            if event == .done {
                                guard emitted else { throw ClientError.streamEnded }
                                continuation.yield(event); continuation.finish(); return
                            }
                            continuation.yield(event)
                        }
                        throw ClientError.streamEnded
                    }
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
