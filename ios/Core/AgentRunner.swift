import Foundation

/// Owns provider protocol state. Audit storage and visible Conversation messages stay separate.
struct AgentRunner: Sendable {
    let model: any AgentModelStreaming
    let executor: any ToolExecuting
    let persistence: ToolExecutionService

    func events(for request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard request.budget.maxWallTimeSeconds > 0 else { throw AgentError.timedOut }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await run(request, continuation: continuation) }
                        group.addTask {
                            try await Task.sleep(for: .seconds(request.budget.maxWallTimeSeconds))
                            throw AgentError.timedOut
                        }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                    continuation.finish()
                } catch {
                    if let error = error as? AgentError { continuation.yield(.failure(error)) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: AgentRequest, continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        let budget = request.budget
        guard budget.maxRounds > 0, budget.maxToolCalls >= 0,
              budget.maxIdenticalToolCallRepeats == 1 else { throw AgentError.budgetExceeded }
        _ = try ToolRegistry.definitions(names: request.enabledTools)
        if let manual = request.manualToolName, !request.enabledTools.contains(manual) { throw AgentError.unavailableTool }
        var transcript = request.messages
        try AgentTranscriptValidator.validate(transcript)
        if !request.enabledTools.isEmpty {
            guard transcript.first?.role == "system" else { throw AgentError.protocolViolation }
            let base = transcript[0]
            transcript[0] = APIMessage(role: "system", content: base.content + "\n\n" + ToolRegistry.securityInstruction)
            // DeepSeek requires past assistant reasoning in requests carrying tools.
            transcript = transcript.map { message in
                guard message.role == "assistant", message.reasoningContent == nil else { return message }
                return APIMessage(role: message.role, content: message.content, imageDataURLs: message.imageDataURLs,
                    reasoningContent: "", toolCalls: message.toolCalls, toolCallID: message.toolCallID)
            }
        }
        var metrics = AgentRunMetrics(), successfulSignatures = Set<String>()
        var seenIDs = Set(transcript.flatMap { $0.toolCalls ?? [] }.map(\.id))
        var physicalCalls = 0, allReasoning = ""
        let clock = ContinuousClock(), runStart = clock.now
        for round in 1...budget.maxRounds {
            try Task.checkCancellation()
            // Reserve the last completion for final streamed synthesis. Earlier rounds can refine.
            let finalOnly = round == budget.maxRounds && round > 1
            let choice: NativeToolChoice = finalOnly ? .none :
                (round == 1 ? request.manualToolName.map(NativeToolChoice.forced) ?? .auto : .auto)
            let input = AgentModelRequest(messages: transcript, model: request.model, thinking: request.thinking,
                reasoningEffort: request.reasoningEffort, toolNames: request.enabledTools, toolChoice: choice)
            let start = clock.now
            var firstToken: ContinuousClock.Instant?, content = "", reasoning = "", reason: String?
            var accumulator = ToolCallAccumulator(), ended = false, usage = AgentUsage()
            var receivedUsage = false
            var contentChunks: [String] = []
            for try await delta in model.streamRound(input) {
                try Task.checkCancellation()
                switch delta {
                case .reasoning(let text):
                    if firstToken == nil { firstToken = clock.now }
                    reasoning += text; allReasoning += text
                    continuation.yield(.reasoningDelta(text))
                case .content(let text):
                    if firstToken == nil { firstToken = clock.now }
                    content += text
                    if request.enabledTools.isEmpty || finalOnly { continuation.yield(.contentDelta(text)) }
                    else { contentChunks.append(text) }
                case .toolCall(let fragment):
                    if firstToken == nil { firstToken = clock.now }
                    try accumulator.append(fragment)
                case .finishReason(let value):
                    guard reason == nil || reason == value else { throw AgentError.protocolViolation }
                    reason = value
                case .detailedUsage(let value): usage = value; receivedUsage = true
                case .done: ended = true
                case .usage: break
                }
                guard content.count + reasoning.count <= budget.maxRoundOutputCharacters else { throw AgentError.budgetExceeded }
            }
            guard ended else { throw ClientError.streamEnded }
            let calls = try accumulator.finalized()
            let finishReason = reason ?? (request.enabledTools.isEmpty ? "stop" : "missing")
            let roundMetrics = AgentRoundMetrics(round: round,
                ttftMilliseconds: firstToken.map { milliseconds(start.duration(to: $0)) },
                latencyMilliseconds: milliseconds(start.duration(to: clock.now)), finishReason: finishReason)
            metrics.rounds.append(roundMetrics); metrics.usage.add(usage)
            if receivedUsage { metrics.usageReportedRoundCount += 1 }
            continuation.yield(.roundCompleted(roundMetrics)); continuation.yield(.usage(usage))
#if DEBUG
            print("[Agent] run=\(request.runID) round=\(round) finish=\(finishReason) calls=\(calls.count) usage=\(usage.promptTokens + usage.completionTokens)")
#endif
            if calls.isEmpty {
                guard finishReason == "stop", !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AgentError.emptyAnswer
                }
                // A tools-enabled round may contain content before tool_calls. Only release
                // its buffered content after stop proves it is the final response round.
                for chunk in contentChunks { continuation.yield(.contentDelta(chunk)) }
                metrics.totalMilliseconds = milliseconds(runStart.duration(to: clock.now))
                if metrics.usageReportedRoundCount == metrics.rounds.count {
                    metrics.estimatedCost = AgentCostEstimate.estimate(model: request.model, usage: metrics.usage)
                }
                continuation.yield(.finalAnswer(content: content, reasoning: allReasoning, metrics: metrics))
                return
            }
            guard finishReason == "tool_calls", !finalOnly, round < budget.maxRounds else { throw AgentError.budgetExceeded }
            guard metrics.tools.count + calls.count <= budget.maxToolCalls else { throw AgentError.budgetExceeded }
            // Validate the whole batch before executing any call.
            let validated = try calls.map { call -> ValidatedToolCall in
                guard seenIDs.insert(call.id).inserted else { throw AgentError.protocolViolation }
                return try ToolRegistry.validate(call, enabled: request.enabledTools)
            }
            transcript.append(APIMessage(role: "assistant", content: content,
                reasoningContent: reasoning, toolCalls: calls))
            for call in validated {
                try Task.checkCancellation()
                continuation.yield(.toolCallStarted(call.call, round: round))
                let toolStart = clock.now
                if successfulSignatures.contains(call.signature) {
                    transcript.append(APIMessage(role: "tool", content: NativeToolResultSerializer.repeated, toolCallID: call.call.id))
                    metrics.tools.append(.init(round: round, toolName: call.call.function.name,
                        latencyMilliseconds: 0, physicallyExecuted: false, status: "repeat_blocked"))
                    continue
                }
                let record = try await persistence.begin(conversationID: request.conversationID,
                    userMessageID: request.userMessageID, assistantMessageID: request.assistantMessageID,
                    toolName: call.call.function.name, query: call.query,
                    toolCallID: call.call.id, roundIndex: round)
                continuation.yield(.toolExecutionStarted(record.id, toolName: call.call.function.name))
                physicalCalls += 1
                let result: String, status: ToolExecutionStatus
                do {
                    let envelope = try await executor.execute(call: call, context: .init(runID: request.runID,
                        conversationID: request.conversationID, round: round, budget: budget))
                    try Task.checkCancellation()
                    let serialized = try NativeToolResultSerializer.success(envelope, budget: budget)
                    _ = try await persistence.succeed(id: record.id, envelope: envelope)
                    result = serialized
                    successfulSignatures.insert(call.signature); status = .succeeded
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        await persistence.cancel(id: record.id)
                        continuation.yield(.toolExecutionCompleted(record.id, status: .cancelled))
                        throw CancellationError()
                    }
                    await persistence.fail(id: record.id, errorCode: "tool_unavailable")
                    status = .failed
                    result = NativeToolResultSerializer.error(code: "tool_unavailable",
                        message: "The read-only tool failed. No successful evidence was obtained. Refine the query or explain the limitation.")
                }
                transcript.append(APIMessage(role: "tool", content: result, toolCallID: call.call.id))
                metrics.tools.append(.init(round: round, toolName: call.call.function.name,
                    latencyMilliseconds: milliseconds(toolStart.duration(to: clock.now)), physicallyExecuted: true, status: status.rawValue))
                continuation.yield(.toolExecutionCompleted(record.id, status: status))
#if DEBUG
                print("[AgentTool] run=\(request.runID) round=\(round) id=\(call.call.id) tool=\(call.call.function.name) args_len=\(call.call.function.arguments.count) result_len=\(result.count) status=\(status.rawValue)")
#endif
            }
            try AgentTranscriptValidator.validate(transcript)
            guard physicalCalls <= budget.maxToolCalls else { throw AgentError.budgetExceeded }
        }
        throw AgentError.budgetExceeded
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
