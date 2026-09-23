import Foundation

enum ClientError: LocalizedError, Sendable { case missingKey, badResponse(Int), invalidConfiguration, streamEnded
    var errorDescription: String? { switch self { case .missingKey: "请先在设置中保存 API Key"; case .badResponse(let code): "服务器返回 \(code)"; case .invalidConfiguration: "连接配置无效"; case .streamEnded: "流意外中断，请手动重试" } }
}

final class APIClient: Sendable {
    func stream(messages: [APIMessage], model: String, thinking: Bool, reasoningEffort: String) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
                    guard let key = KeychainStore.readAPIKey(), !key.isEmpty else { throw ClientError.missingKey }
                    var headers = ["Content-Type": "application/json", "X-Request-ID": UUID().uuidString, "Authorization": "Bearer \(key)"]
                    var request = URLRequest(url: endpoint); request.httpMethod = "POST"; headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                    var body: [String: Any] = ["model": model, "stream": true, "messages": messages.map { ["role": $0.role, "content": $0.wireContent] }]
                    body["thinking"] = ["type": thinking ? "enabled" : "disabled"]; body["reasoning_effort"] = reasoningEffort
                    request.httpBody = try JSONSerialization.data(withJSONObject: body); request.timeoutInterval = 610
                    for attempt in 0..<3 {
                        let (bytes, response) = try await URLSession.shared.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidConfiguration }
                        if http.statusCode == 429 || (500...599).contains(http.statusCode), attempt < 2 {
                            let delay = UInt64(Double(500 * (1 << attempt)) * Double.random(in: 0.75...1.25) * 1_000_000)
                            try await Task.sleep(nanoseconds: delay); continue
                        }
                        guard http.statusCode == 200 else { throw ClientError.badResponse(http.statusCode) }
                        var parser = SSEParser(); var emitted = false
                        for try await byte in bytes {
                            for event in parser.append(Data([byte])) {
                                if case .content = event { emitted = true }
                                if case .reasoning = event { emitted = true }
                                continuation.yield(event)
                                if event == .done { continuation.finish(); return }
                            }
                        }
                        for event in parser.finish() { continuation.yield(event); if event == .done { continuation.finish(); return } }
                        if emitted { throw ClientError.streamEnded }; continuation.finish(); return
                    }
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
