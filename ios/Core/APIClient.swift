import Foundation

enum ClientError: LocalizedError, Sendable {
    case missingKey, badResponse(Int), invalidConfiguration, streamEnded
    case modelDoesNotSupportImages(String)
    case tooManyImages(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey: "请先在设置中保存 API Key"
        case .badResponse(let code): "服务器返回 \(code)"
        case .invalidConfiguration: "连接配置无效"
        case .streamEnded: "流意外中断，请手动重试"
        case .modelDoesNotSupportImages(let model): "模型 \(model) 不支持图片输入，请切换到 deepseek-flash。"
        case .tooManyImages(let count): "一次最多发送 6 张图片，当前为 \(count) 张。"
        }
    }
}

enum DeepSeekModelCompatibility {
    static let flash = "deepseek-flash"
    static let pro = "deepseek-v4-pro"

    /// Request-time mapping keeps existing SwiftData conversations usable
    /// after official legacy aliases are retired, without a store migration.
    static func requestModel(for storedModel: String) -> String {
        switch storedModel.lowercased() {
        case "deepseek-chat", "deepseek-reasoner", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp":
            flash
        default:
            storedModel
        }
    }

    static func supportsImages(_ requestModel: String) -> Bool {
        requestModel.lowercased() == flash
    }
}

final class APIClient: Sendable {
    private let apiKeyProvider: @Sendable () -> String?

    init(apiKeyProvider: @escaping @Sendable () -> String? = { KeychainStore.readAPIKey() }) {
        self.apiKeyProvider = apiKeyProvider
    }

    func stream(messages: [APIMessage], model: String, thinking: Bool, reasoningEffort: String) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
                    let requestModel = DeepSeekModelCompatibility.requestModel(for: model)
                    let imageCount = messages.reduce(0) { $0 + $1.imageDataURLs.count }
                    guard imageCount <= 6 else { throw ClientError.tooManyImages(imageCount) }
                    guard imageCount == 0 || DeepSeekModelCompatibility.supportsImages(requestModel) else {
                        throw ClientError.modelDoesNotSupportImages(requestModel)
                    }
                    guard let key = apiKeyProvider(), !key.isEmpty else { throw ClientError.missingKey }
                    var headers = ["Content-Type": "application/json", "X-Request-ID": UUID().uuidString, "Authorization": "Bearer \(key)"]
                    var request = URLRequest(url: endpoint); request.httpMethod = "POST"; headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                    var body: [String: Any] = [
                        "model": requestModel,
                        "stream": true,
                        "stream_options": ["include_usage": true],
                        "messages": messages.map { ["role": $0.role, "content": $0.wireContent] }
                    ]
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
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            for event in parser.appendEventLine(line) {
                                if case .content = event { emitted = true }
                                if case .reasoning = event { emitted = true }
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
