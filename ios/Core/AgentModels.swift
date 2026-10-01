import Foundation

struct NativeToolCall: Codable, Equatable, Sendable {
    struct Function: Codable, Equatable, Sendable {
        let name: String
        let arguments: String
    }
    let id: String
    let type: String
    let function: Function
    var wireValue: [String: Any] {
        ["id": id, "type": type, "function": ["name": function.name, "arguments": function.arguments]]
    }
}

struct ToolCallFragment: Equatable, Sendable {
    let index: Int
    let id: String?
    let type: String?
    let name: String?
    let arguments: String?
}

enum AgentError: LocalizedError, Sendable, Equatable {
    case protocolViolation, invalidArguments, unavailableTool, budgetExceeded, timedOut, emptyAnswer
    var errorDescription: String? {
        switch self {
        case .protocolViolation: "工具调用协议无效，请重试。"
        case .invalidArguments: "模型返回了无效的工具参数，请重试。"
        case .unavailableTool: "模型请求的工具未开放。"
        case .budgetExceeded: "已达到本次工具调用上限，请缩小问题范围后重试。"
        case .timedOut: "本次工具处理超时，请重试。"
        case .emptyAnswer: "模型没有返回有效回答，请重试。"
        }
    }
}

struct ToolCallAccumulator: Sendable {
    private struct Partial: Sendable {
        var id = "", type = "", name = "", arguments = ""
    }
    private var partials: [Int: Partial] = [:]
    mutating func append(_ fragment: ToolCallFragment) throws {
        guard (0..<16).contains(fragment.index) else { throw AgentError.protocolViolation }
        var partial = partials[fragment.index] ?? Partial()
        if let id = fragment.id, !id.isEmpty {
            guard partial.id.isEmpty || partial.id == id else { throw AgentError.protocolViolation }
            partial.id = id
        }
        if let type = fragment.type, !type.isEmpty {
            guard partial.type.isEmpty || partial.type == type else { throw AgentError.protocolViolation }
            partial.type = type
        }
        if let name = fragment.name { partial.name += name }
        if let arguments = fragment.arguments { partial.arguments += arguments }
        guard partial.arguments.utf8.count <= 8_192, partial.name.count <= 80, partial.id.count <= 160 else {
            throw AgentError.invalidArguments
        }
        partials[fragment.index] = partial
    }
    func finalized() throws -> [NativeToolCall] {
        var seen = Set<String>()
        return try partials.keys.sorted().map { index in
            let partial = partials[index]!
            guard !partial.id.isEmpty, partial.type == "function", !partial.name.isEmpty,
                  seen.insert(partial.id).inserted else { throw AgentError.protocolViolation }
            return NativeToolCall(id: partial.id, type: partial.type, function: .init(name: partial.name, arguments: partial.arguments))
        }
    }
}

struct AgentUsage: Codable, Equatable, Sendable {
    var promptTokens = 0
    var completionTokens = 0
    var reasoningTokens = 0
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    mutating func add(_ value: AgentUsage) {
        promptTokens += value.promptTokens; completionTokens += value.completionTokens
        reasoningTokens += value.reasoningTokens; cacheHitTokens += value.cacheHitTokens
        cacheMissTokens += value.cacheMissTokens
    }
}

struct AgentRoundMetrics: Codable, Equatable, Sendable {
    let round: Int
    let ttftMilliseconds: Double?
    let latencyMilliseconds: Double
    let finishReason: String
}

struct AgentToolMetrics: Codable, Equatable, Sendable {
    let round: Int
    let toolName: String
    let latencyMilliseconds: Double
    let physicallyExecuted: Bool
    let status: String
}

struct AgentRunMetrics: Codable, Equatable, Sendable {
    var rounds: [AgentRoundMetrics] = []
    var tools: [AgentToolMetrics] = []
    var usage = AgentUsage()
    var totalMilliseconds: Double = 0
    var finalMilliseconds: Double { rounds.last?.latencyMilliseconds ?? 0 }
    var toolCallCount: Int { tools.count }
}

struct AgentLoopBudget: Sendable, Equatable {
    var maxRounds = 3
    var maxToolCalls = 5
    // A successful canonical call may be physically executed once per run.
    var maxIdenticalToolCallRepeats = 1
    var maxWallTimeSeconds: Double = 180
    var maxToolResultCharacters = 6_000
    var maxToolResultEstimatedTokens = 2_000
    var maxRoundOutputCharacters = 200_000
    static let production = AgentLoopBudget()
}

struct AgentRequest: Sendable {
    let runID: UUID
    let conversationID: UUID
    let userMessageID: UUID
    let assistantMessageID: UUID
    let model: String
    let thinking: Bool
    let reasoningEffort: String
    // Already assembled immutable snapshots of system, Profile, history, prior tools,
    // Memory, clock and current user/images. Appended protocol messages never rebuild it.
    let messages: [APIMessage]
    let enabledTools: [String]
    let manualToolName: String?
    let budget: AgentLoopBudget

    init(runID: UUID = UUID(), conversationID: UUID, userMessageID: UUID, assistantMessageID: UUID,
         model: String, thinking: Bool, reasoningEffort: String, messages: [APIMessage],
         enabledTools: [String] = [], manualToolName: String? = nil, budget: AgentLoopBudget = .production) {
        self.runID = runID; self.conversationID = conversationID
        self.userMessageID = userMessageID; self.assistantMessageID = assistantMessageID
        self.model = model; self.thinking = thinking; self.reasoningEffort = reasoningEffort
        self.messages = messages; self.enabledTools = enabledTools
        self.manualToolName = manualToolName; self.budget = budget
    }
}

struct AgentHistorySnapshot: Sendable {
    let role: String
    let content: String
    let reasoning: String
}

enum AgentInitialMessages {
    static func preservingReasoning(_ messages: [APIMessage], history: [AgentHistorySnapshot]) -> [APIMessage] {
        var index = 0
        return messages.map { message in
            guard index < history.count, message.role == history[index].role,
                  message.content == history[index].content else { return message }
            let previous = history[index]; index += 1
            guard message.role == "assistant" else { return message }
            return APIMessage(role: message.role, content: message.content,
                imageDataURLs: message.imageDataURLs, reasoningContent: previous.reasoning)
        }
    }
}

enum AgentEvent: Sendable {
    case reasoningDelta(String)
    case contentDelta(String)
    case toolCallStarted(NativeToolCall, round: Int)
    case toolExecutionStarted(UUID, toolName: String)
    case toolExecutionCompleted(UUID, status: ToolExecutionStatus)
    case roundCompleted(AgentRoundMetrics)
    case usage(AgentUsage)
    case finalAnswer(content: String, reasoning: String, metrics: AgentRunMetrics)
    case failure(AgentError)
}

enum NativeToolChoice: Sendable, Equatable {
    case auto, none, forced(String)
    var wireValue: Any {
        switch self {
        case .auto: "auto"
        case .none: "none"
        case .forced(let name): ["type": "function", "function": ["name": name]]
        }
    }
}

struct AgentModelRequest: Sendable {
    let messages: [APIMessage]
    let model: String
    let thinking: Bool
    let reasoningEffort: String
    let toolNames: [String]
    let toolChoice: NativeToolChoice
    var strict = false
}

protocol AgentModelStreaming: Sendable {
    func streamRound(_ request: AgentModelRequest) -> AsyncThrowingStream<StreamDelta, Error>
}
