import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

/// No production seam or prompt changes. The E2E harness invokes the same public
/// production components as ChatView.send(), but is not a SwiftUI/device UI test.
@MainActor final class IntegrationAcceptanceTests: XCTestCase {
    // Selected after the provider returned the public official platform page but
    // did not recall the accounting-field docs. Frozen Memory fixtures are unrelated.
    private let publicQuery = "DeepSeek API Platform auto-caching 官方平台的自动缓存与缓存命中折扣"

    func testOptInPublicNetworkReadiness() async throws {
        let key = try realKey()
        let start = ContinuousClock.now
        var answer = ""
        for try await delta in APIClient(apiKey: key).stream(messages: [
            .init(role: "user", content: "2+2 等于多少？只回答数字。")
        ], model: DeepSeekModelCompatibility.flash, thinking: false, reasoningEffort: "low") {
            if case .content(let value) = delta { answer += value }
        }
        XCTAssertTrue(answer.contains("4"))
        try write(["purpose": "Explicitly recorded no-tool simulator network preflight; outside Research route",
            "answer": answer, "duration": String(describing: start.duration(to: .now))], named: "network-readiness.json")
    }

    func testResearchImageAndPersonalContextCoexistWithoutDuplication() throws {
        let image = "data:image/png;base64,YWNjZXB0YW5jZS1pbWFnZQ=="
        let assembled = try assemble(sources: [source()], image: image)
        let request = modelRequest(messages: assembled.messages)
        let body = try APIClient.requestBody(request)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(wire["messages"] as? [[String: Any]])
        let images = messages.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.compactMap {
            ($0["image_url"] as? [String: Any])?["url"] as? String
        }
        XCTAssertEqual(images, [image])
        XCTAssertLessThan(body.count, APIClient.maximumRequestBodyBytes)
        XCTAssertEqual(assembled.messages.filter { $0.content.contains("Web research evidence:") }.count, 1)
        XCTAssertFalse(assembled.messages.contains { $0.role == "tool" })
        XCTAssertEqual(assembled.messages.filter { $0.content == profile.messageContent }.count, 1)
        XCTAssertEqual(assembled.messages.filter { $0.content == memory.messageContent }.count, 1)
        let prior = try XCTUnwrap(assembled.messages.first { $0.content.contains("UNTRUSTED_PRIOR_TOOL_RESULTS_JSON:") })
        XCTAssertTrue(prior.content.contains("［9］"))
        XCTAssertFalse(prior.content.contains("[9]"))
    }

    func testSynthesisCancellationDoesNotProduceSuccessfulTurn() async throws {
        let model = AcceptanceBlockingModel()
        let service = ToolExecutionService(modelContainer: try AgentTestFixtures.container())
        let request = agentRequest(messages: try assemble(sources: [source()]).messages, tools: [], thinking: false)
        let task = Task { @MainActor in
            var generationActive = true
            var final = false
            var cancellationObserved = false
            do {
                for try await event in AgentRunner(model: model, executor: AcceptancePublicFixtureExecutor(), persistence: service).events(for: request) {
                    if case .finalAnswer = event { final = true }
                }
            } catch is CancellationError {
                cancellationObserved = true
            } catch {
                XCTFail("Unexpected cancellation error: \(String(describing: type(of: error)))")
            }
            // AsyncThrowingStream may finish normally when its iterator is
            // cancelled. Like ChatView, run cleanup after either termination;
            // observe it afterwards, not inside a return evaluated before defer.
            generationActive = false
            return (final, generationActive, cancellationObserved || Task.isCancelled)
        }
        await model.waitUntilStarted()
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result.0)
        XCTAssertFalse(result.1)
        XCTAssertTrue(result.2)
        XCTAssertNil(CompletedTurnEligibility.snapshot(successfulCompletion: false, persistenceSucceeded: true,
            conversationID: UUID(), userMessageID: UUID(), userText: "research", assistantMessageID: UUID(), assistantText: ""))
        // Actual ChatView cleanup is separately source-audited; this controlled
        // harness cannot claim a device UI assertion.
    }

    func testOptInExplicitResearchEndToEnd() async throws {
        let key = try realKey()
        var report: [String: Any] = ["productionBaseline": "cb87131", "query": publicQuery,
            "harnessBoundary": "Production components; not SwiftUI UI automation"]
        do {
            let input = "深度研究 " + publicQuery
            let route = try XCTUnwrap(AssistantIntentRouter.preferredTool(for: input))
            XCTAssertEqual(route, "start_deep_search")
            guard case .deepResearch(let query) = AssistantIntentRouter.directCall(for: route, query: input) else {
                throw AgentError.unavailableTool
            }
            report["route"] = route; report["deepResearchRouteCount"] = 1
            let gathered = try await LocalResearchService().gatherWithMetadata(query: query)
            report["provider"] = gathered.providerUsed.rawValue
            report["searchResultCount"] = gathered.sources.count
            report["successfulPageFetchCount"] = gathered.sources.filter { !$0.pageText.isEmpty }.count
            report["snippetOnlyFallbackCount"] = gathered.sources.filter { $0.pageText.isEmpty }.count
            report["sources"] = gathered.sources.enumerated().map { index, source in
                ["number": index + 1, "title": source.title, "url": source.url.absoluteString,
                 "pageCharacters": source.pageText.count, "snippetCharacters": source.snippet.count] as [String: Any]
            }
            XCTAssertFalse(gathered.sources.isEmpty)
            XCTAssertTrue(gathered.sources.contains { !$0.pageText.isEmpty }, "At least one real page fetch required")
            let assembled = try assemble(sources: gathered.sources, query: query)
            let usage = assembled.usage
            report["historyCharacters"] = usage.historyRetainedCharacters
            report["evidenceCharacters"] = usage.evidenceRetainedCharacters
            report["sourceCount"] = usage.sourceCount
            report["truncationOccurred"] = usage.wasEvidenceTrimmed || usage.wasHistoryTrimmed
            report["totalTextCharacters"] = usage.totalRetainedTextCharacters
            report["maximumInputCharacters"] = usage.maximumInputCharacters
            report["estimatedRequestBytes"] = try APIClient.requestBody(modelRequest(messages: assembled.messages)).count
            XCTAssertLessThanOrEqual(usage.totalRetainedTextCharacters, usage.maximumInputCharacters)
            XCTAssertLessThanOrEqual(usage.historyRetainedCharacters, ResearchContextBudgetPolicy.chatDefault.maximumHistoryCharacters)
            XCTAssertLessThanOrEqual(usage.evidenceRetainedCharacters, ResearchContextBudgetPolicy.chatDefault.maximumEvidenceCharacters)

            let schema = Schema([Conversation.self, ChatMessage.self, ToolExecutionRecord.self,
                UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
                isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            let store = MemoryStore(modelContainer: container)
            let beforeProfile = try await store.getOrCreateProfile(scopeID: MemoryScope.localDefault)
            let beforeMemory = try await store.insertMemory(scopeID: MemoryScope.localDefault,
                draft: .init(kind: .preference, canonicalText: "用户偏好简洁的回答。"))
            let conversation = Conversation(systemPrompt: "You are a reliable assistant.", mode: "research")
            container.mainContext.insert(conversation)
            let user = ChatMessage(role: "user", content: input, conversation: conversation)
            let assistant = ChatMessage(role: "assistant", conversation: conversation)
            container.mainContext.insert(user); container.mainContext.insert(assistant)
            try container.mainContext.save()
            let audit = AcceptanceAuditedModel(underlying: APIClient(apiKey: key))
            let executor = AcceptanceCountingExecutor(underlying: ReadOnlyToolExecutor(localSearch: { _, _ in [] }))
            let request = AgentRequest(conversationID: conversation.id, userMessageID: user.id,
                assistantMessageID: assistant.id, model: DeepSeekModelCompatibility.flash, thinking: true,
                reasoningEffort: "low", messages: assembled.messages, enabledTools: [],
                budget: AgentLoopBudget(maxWallTimeSeconds: 610))
            var answer = "", metrics: AgentRunMetrics?
            for try await event in AgentRunner(model: audit, executor: executor,
                persistence: ToolExecutionService(modelContainer: container)).events(for: request) {
                if case .finalAnswer(let text, let reasoning, let value) = event {
                    answer = text; assistant.content = text; assistant.reasoning = reasoning; metrics = value
                }
            }
            try container.mainContext.save()
            let captured = await audit.captured()
            let finalRequest = try XCTUnwrap(captured.first)
            let currentEvidence = finalRequest.messages.filter { $0.content.contains("Web research evidence:") }
            report["messageRoles"] = finalRequest.messages.map(\.role)
            report["messageContentCharacters"] = finalRequest.messages.map { $0.content.count }
            report["currentResearchEvidenceOccurrences"] = currentEvidence.count
            report["currentResearchRoleToolDuplicates"] = finalRequest.messages.filter { $0.role == "tool" }.count
            report["nativeWebSearchCalls"] = await executor.count()
            report["synthesisCompletionCount"] = captured.count
            report["finalAnswer"] = answer // public query only; no raw evidence body
            report["persistedAssistantNonempty"] = !assistant.content.isEmpty
            if let metrics { report["usage"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics)) }
            XCTAssertEqual(currentEvidence.count, 1)
            XCTAssertFalse(finalRequest.messages.contains { $0.role == "tool" })
            XCTAssertTrue(finalRequest.toolNames.isEmpty)
            let executionCount = await executor.count()
            XCTAssertEqual(executionCount, 0)
            XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let citationNumbers = Self.citations(in: answer)
            report["citationNumbers"] = citationNumbers
            XCTAssertFalse(citationNumbers.isEmpty)
            XCTAssertTrue(citationNumbers.allSatisfy { (1...gathered.sources.count).contains($0) })
            // A publicly verifiable CURRENT official source fact. Do not require
            // a specific API field when the provider has not returned its docs.
            let citedSources = citationNumbers.map { gathered.sources[$0 - 1] }
            let publicFact = "Auto-caching with reduced cache hit pricing"
            let lowerAnswer = answer.lowercased()
            let describesCaching = lowerAnswer.contains("自动缓存") || lowerAnswer.contains("auto-caching")
            let describesDiscount = (lowerAnswer.contains("命中") || lowerAnswer.contains("cache hit")) &&
                ["价格", "折扣", "低", "优惠", "price", "pricing", "discount"].contains { lowerAnswer.contains($0) }
            let witness = citedSources.first { $0.url.host == "www.deepseek.com" && $0.url.path.contains("/platform/") &&
                ($0.snippet + " " + $0.pageText).localizedCaseInsensitiveContains(publicFact) }
            let verified = witness != nil && describesCaching && describesDiscount && currentEvidence.contains {
                $0.content.localizedCaseInsensitiveContains(publicFact)
            }
            report["verifiedPublicSourceFact"] = publicFact
            report["verifiedFactSourceURL"] = witness?.url.absoluteString ?? ""
            report["actualSourceFactVerified"] = verified
            XCTAssertTrue(verified, "Cited retained official evidence must support the public caching fact")
            let afterProfile = try await store.getOrCreateProfile(scopeID: MemoryScope.localDefault)
            let afterMemory = try await store.listMemories(scopeID: MemoryScope.localDefault)
            report["profileUnchanged"] = beforeProfile == afterProfile
            report["memoryUnchanged"] = afterMemory == [beforeMemory]
            XCTAssertEqual(beforeProfile, afterProfile)
            XCTAssertEqual(afterMemory, [beforeMemory])
            // No extractor is called by this harness. CompletedTurnEligibility in
            // production passes only visible user/final answer, never raw evidence.
            report["memoryBoundary"] = "No raw evidence writes; production eligibility source-audited"
            try write(report, named: "explicit-research-e2e.json")
        } catch {
            report["errorType"] = String(describing: type(of: error))
            report["error"] = error.localizedDescription
            try write(report, named: "explicit-research-e2e.json")
            throw error
        }
    }

    func testOptInNativeProtocolSmoke() async throws {
        let key = try realKey()
        let cases: [(String, String, Bool, Bool)] = [
            ("no-tool", "2+2 等于多少？只回答数字。", false, false),
            ("native-search", "联网查一下 DeepSeek API context caching 的官方文档，引用实际来源。", false, true),
            ("refinement", "先搜索官方测试公园名称，再根据该名称查开放时间。第一轮不含时间时必须针对名称再次查询。", false, true),
            ("thinking-reentry", "联网搜索 DeepSeek API context caching 的官方文档，说明一个公开事实并引用来源。", true, true)
        ]
        var records: [[String: Any]] = []
        for (name, query, thinking, tools) in cases {
            var record: [String: Any] = ["case": name, "thinking": thinking]
            do {
                if name == "native-search" { XCTAssertEqual(AssistantIntentRouter.preferredTool(for: query), "web_search") }
                let audit = AcceptanceAuditedModel(underlying: APIClient(apiKey: key))
                let executor: any ToolExecuting = name == "refinement" ? AcceptancePublicFixtureExecutor() :
                    ReadOnlyToolExecutor(localSearch: { _, _ in [] })
                let request = agentRequest(messages: [.init(role: "system", content: "You are a reliable assistant. Use actual tool results, and answer concisely."),
                    .init(role: "system", content: RuntimeClockContext.current().messageContent), .init(role: "user", content: query)],
                    tools: tools ? ["web_search"] : [], thinking: thinking)
                var answer = "", metrics: AgentRunMetrics?
                for try await event in AgentRunner(model: audit, executor: executor,
                    persistence: ToolExecutionService(modelContainer: try AgentTestFixtures.container())).events(for: request) {
                    if case .finalAnswer(let text, _, let value) = event { answer = text; metrics = value }
                }
                let rounds = await audit.captured()
                let thinkingObserved = rounds.dropFirst().contains { round in
                    round.messages.contains { $0.role == "assistant" && $0.toolCalls != nil && $0.reasoningContent?.isEmpty == false }
                        && round.messages.contains { $0.role == "tool" && $0.toolCallID != nil }
                }
                for round in rounds { try AgentTranscriptValidator.validate(round.messages) }
                let physical = metrics?.tools.filter(\.physicallyExecuted).count ?? 0
                let passed = !answer.isEmpty && (tools ? physical > 0 : physical == 0)
                    && (!thinking || thinkingObserved)
                    && (name != "refinement" || (physical >= 2 && rounds.count >= 3))
                record["passed"] = passed; record["protocolError"] = false
                record["thinkingReentryObserved"] = thinkingObserved
                record["physicalCalls"] = physical; record["rounds"] = rounds.count
                record["answer"] = answer
                record["toolBoundary"] = name == "refinement" ? "Controlled public fixture; live model decisions and transport" : "Real public search / no tool"
                if let metrics { record["metrics"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics)) }
                XCTAssertTrue(passed, "See native smoke record: \(name)")
            } catch {
                record["passed"] = false; record["error"] = error.localizedDescription
                record["protocolError"] = error as? AgentError == .protocolViolation
                XCTFail("Smoke \(name): \(String(describing: type(of: error)))")
            }
            records.append(record)
        }
        try write(["cases": records], named: "native-protocol-smoke.json")
    }

    private var profile: ProfileContextSnapshot {
        let content = "Optional untrusted test user profile: prefers concise answers."
        return .init(messageContent: content, injected: [], characterCount: content.count, estimatedTokens: 20)
    }
    private var memory: MemoryContextSnapshot {
        let content = "Optional untrusted atomic memory: test user prefers clear explanations."
        return .init(messageContent: content, injected: [], characterCount: content.count, estimatedTokens: 20)
    }
    private func source() -> ResearchSource {
        .init(title: "Controlled public documentation", url: URL(string: "https://example.com/docs")!,
            snippet: "Public information", pageText: "prompt_cache_hit_tokens records cache hits.")
    }
    private func assemble(sources: [ResearchSource], query: String = "context caching", image: String? = nil) throws -> ResearchAssembledRequest {
        let prior = "UNTRUSTED_PRIOR_TOOL_RESULTS_JSON: {\"old_label\":\"[9]\",\"note\":\"Earlier documentation lookup\"}"
        return try ChatRequestAssembler.researchMessages(system: "You are a reliable assistant.", history: [],
            researchQuestion: query, researchSources: sources, profileContext: profile,
            toolHistoryContext: .init(executions: [], messageContent: prior, characterCount: prior.count, estimatedTokens: 30),
            memoryContext: memory, runtimeClockContext: RuntimeClockContext.current(),
            newUserText: "深度研究 " + query + "。依据当前官方平台页面说明自动缓存与缓存命中定价的关系，并用 [n] 引用来源。", imageDataURLs: image.map { [$0] } ?? [])
    }
    private func agentRequest(messages: [APIMessage], tools: [String], thinking: Bool) -> AgentRequest {
        .init(conversationID: UUID(), userMessageID: UUID(), assistantMessageID: UUID(), model: DeepSeekModelCompatibility.flash,
            thinking: thinking, reasoningEffort: "low", messages: messages, enabledTools: tools,
            manualToolName: tools.isEmpty ? nil : "web_search")
    }
    private func modelRequest(messages: [APIMessage]) -> AgentModelRequest {
        .init(messages: messages, model: DeepSeekModelCompatibility.flash, thinking: true, reasoningEffort: "low", toolNames: [], toolChoice: .auto)
    }
    private func realKey() throws -> String {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_INTEGRATION_ACCEPTANCE_EVALUATION"] == "1", "Opt-in real acceptance only")
        return try XCTUnwrap(ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"])
    }
    private func write(_ object: [String: Any], named: String) throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INTEGRATION_ACCEPTANCE_REPORT_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(named))
    }
    private static func citations(in text: String) -> [Int] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)
        return Array(Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) }
        })).sorted()
    }
}

private actor AcceptanceAuditedModel: AgentModelStreaming {
    let underlying: any AgentModelStreaming
    private var requests: [AgentModelRequest] = []
    init(underlying: any AgentModelStreaming) { self.underlying = underlying }
    private func record(_ request: AgentModelRequest) { requests.append(request) }
    func captured() -> [AgentModelRequest] { requests }
    nonisolated func streamRound(_ request: AgentModelRequest) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.record(request)
                do {
                    for try await value in underlying.streamRound(request) { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor AcceptanceCountingExecutor: ToolExecuting {
    let underlying: any ToolExecuting
    private var executions = 0
    init(underlying: any ToolExecuting) { self.underlying = underlying }
    func count() -> Int { executions }
    func execute(call: ValidatedToolCall, context: ToolExecutionContext) async throws -> ToolResultEnvelope {
        executions += 1
        return try await underlying.execute(call: call, context: context)
    }
}

private actor AcceptancePublicFixtureExecutor: ToolExecuting {
    private var count = 0
    func execute(call: ValidatedToolCall, context: ToolExecutionContext) async throws -> ToolResultEnvelope {
        count += 1
        let text = count == 1 ? "The official test park is named Green Valley Park. Opening time is absent; query Green Valley Park opening time next." :
            "Green Valley Park opens at 09:00. Controlled public evaluation fixture, not a real park."
        return try ToolResultEnvelopeBuilder.webSearch(toolName: "web_search", query: call.query, provider: "controlled",
            sources: [.init(title: "Public test park reference", url: URL(string: "https://example.com/park")!, snippet: text)])
    }
}

private actor AcceptanceBlockingModel: AgentModelStreaming {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    private func signal() { started = true; waiter?.resume(); waiter = nil }
    nonisolated func streamRound(_ request: AgentModelRequest) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.signal()
                do {
                    continuation.yield(.reasoning("Gather complete; synthesis in progress"))
                    try await Task.sleep(for: .seconds(30))
                    continuation.yield(.content("Must never arrive after cancellation"))
                    continuation.yield(.finishReason("stop")); continuation.yield(.done); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
