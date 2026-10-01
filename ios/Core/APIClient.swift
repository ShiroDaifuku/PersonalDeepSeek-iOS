import Foundation

enum ClientError: LocalizedError, Sendable {
    case missingKey, badResponse(Int), invalidConfiguration, streamEnded
    case modelDoesNotSupportImages(String)
    case tooManyImages(Int)
    case requestBodyTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey: "请先在设置中保存 API Key"
        case .badResponse(let code): "服务器返回 \(code)"
        case .invalidConfiguration: "连接配置无效"
        case .streamEnded: "流意外中断，请手动重试"
        case .modelDoesNotSupportImages(let model): "模型 \(model) 不支持图片输入，请切换到 deepseek-flash。"
        case .tooManyImages(let count): "一次最多发送 6 张图片，当前为 \(count) 张。"
        case .requestBodyTooLarge: "图片和文字的请求体超过 48 MiB，请减少附件后重试。"
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

final class APIClient: Sendable, AgentModelStreaming {
    static let maximumRequestBodyBytes = 48 * 1_024 * 1_024
    private let suppliedKey: String?
    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?

    init(apiKey: String? = nil, session: URLSession = .shared,
         apiKeyProvider: @escaping @Sendable () -> String? = { KeychainStore.readAPIKey() }) {
        suppliedKey = apiKey; self.session = session; self.apiKeyProvider = apiKeyProvider
    }
    func stream(messages: [APIMessage], model: String, thinking: Bool, reasoningEffort: String) -> AsyncThrowingStream<StreamDelta, Error> {
        streamRound(.init(messages: messages, model: model, thinking: thinking,
            reasoningEffort: reasoningEffort, toolNames: [], toolChoice: .auto))
    }

    static func requestBody(_ input: AgentModelRequest) throws -> Data {
        try AgentTranscriptValidator.validate(input.messages)
        let requestModel = DeepSeekModelCompatibility.requestModel(for: input.model)
        let imageCount = input.messages.reduce(0) { $0 + $1.imageDataURLs.count }
        guard imageCount <= 6 else { throw ClientError.tooManyImages(imageCount) }
        guard imageCount == 0 || DeepSeekModelCompatibility.supportsImages(requestModel) else {
            throw ClientError.modelDoesNotSupportImages(requestModel)
        }
        var body: [String: Any] = ["model": requestModel, "stream": true,
            "messages": input.messages.map(\.wireMessage),
            "thinking": ["type": input.thinking ? "enabled" : "disabled"],
            "reasoning_effort": input.reasoningEffort,
            "stream_options": ["include_usage": true]]
        if !input.toolNames.isEmpty {
            body["tools"] = try ToolRegistry.definitions(names: input.toolNames, strict: input.strict)
            body["tool_choice"] = input.toolChoice.wireValue
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= maximumRequestBodyBytes else { throw ClientError.requestBodyTooLarge(data.count) }
        return data
    }

    func streamRound(_ input: AgentModelRequest) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = URL(string: input.strict ? "https://api.deepseek.com/beta/chat/completions" : "https://api.deepseek.com/chat/completions")!
                    guard let key = suppliedKey ?? apiKeyProvider(), !key.isEmpty else { throw ClientError.missingKey }
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
