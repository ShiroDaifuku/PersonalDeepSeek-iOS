import Foundation
import SwiftData
import SwiftUI

/// All SwiftData models stay on the main actor. The same application MemoryService
/// supplies bounded snapshots and accepts only persisted, successfully completed turns.
@MainActor
final class CompanionChatViewModel: ObservableObject {
    @Published private(set) var current: Conversation?
    @Published private(set) var isGenerating = false
    @Published private(set) var streamingText = ""
    @Published private(set) var errorText: String?
    private let memoryService: MemoryService
    private let client: any AgentModelStreaming
    private var generation: Task<Void, Never>?

    init(memoryService: MemoryService, client: any AgentModelStreaming = APIClient()) {
        self.memoryService = memoryService
        self.client = client
    }

    func select(_ conversation: Conversation?) {
        guard !isGenerating,
              conversation == nil || conversation?.mode == CompanionChatPolicy.conversationMode else { return }
        current = conversation
        errorText = nil
    }

    func cancel() { generation?.cancel() }
    func waitUntilIdle() async { await generation?.value }

    func send(_ raw: String, context: ModelContext) {
        guard !isGenerating else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= CompanionChatPolicy.maximumUserCharacters else {
            errorText = "陪伴模式一次最多发送 4000 字，请缩短后重试。"; return
        }
        let conversation: Conversation
        let created = current == nil
        if let current {
            guard current.mode == CompanionChatPolicy.conversationMode else { return }
            conversation = current
        } else {
            conversation = Conversation(title: String(text.prefix(24)), systemPrompt: CompanionChatPolicy.persona,
                model: DeepSeekModelCompatibility.flash, mode: CompanionChatPolicy.conversationMode)
            context.insert(conversation)
        }
        let history = Self.boundedHistory(conversation.messages)
        let user = ChatMessage(role: "user", content: text, conversation: conversation)
        let assistant = ChatMessage(role: "assistant", conversation: conversation)
        // Deterministic ordering even when two messages are created in the same clock tick.
        assistant.createdAt = user.createdAt.addingTimeInterval(0.001)
        context.insert(user); context.insert(assistant)
        do { try context.save() }
        catch {
            context.delete(assistant); context.delete(user)
            if created { context.delete(conversation) }
            errorText = error.localizedDescription
            return
        }
        current = conversation; isGenerating = true; streamingText = ""; errorText = nil
        generation = Task {
            defer { isGenerating = false; streamingText = ""; generation = nil }
            do {
                try Task.checkCancellation()
                async let profile = memoryService.readyProfileForChat()
                let memory = await memoryService.contextForChat(
                    input: .init(primaryText: text, excludingConversationID: conversation.id), currentUserText: text)
                let profileSnapshot = await profile
                let profileContext = profileSnapshot.flatMap {
                    ProfileContextBuilder.build(profile: $0, currentUserText: text, retrievedMemoryContext: memory).context
                }
                try Task.checkCancellation()
                let messages = ChatRequestAssembler.messages(system: conversation.systemPrompt, history: history,
                    profileContext: profileContext, memoryContext: memory,
                    runtimeClockContext: .current(), newUserText: text)
                var answer = "", receivedDone = false, finishReason: String?, byteCount = 0
                var lastPaint = Date.distantPast
                for try await delta in client.streamRound(CompanionChatPolicy.request(messages: messages)) {
                    try Task.checkCancellation()
                    switch delta {
                    case .content(let fragment):
                        byteCount += fragment.utf8.count
                        guard byteCount <= 32_768 else { throw ClientError.responseBodyTooLarge(32_768) }
                        answer += fragment
                        if Date().timeIntervalSince(lastPaint) >= 0.08 {
                            streamingText = answer; lastPaint = Date()
                        }
                    case .finishReason(let reason): finishReason = reason
                    case .done: receivedDone = true
                    case .toolCall: throw AgentError.unavailableTool
                    default: break
                    }
                }
                try Task.checkCancellation()
                guard receivedDone, finishReason == "stop", !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ClientError.streamEnded
                }
                assistant.content = answer
                let completedAt = max(Date(), user.createdAt.addingTimeInterval(0.001))
                assistant.createdAt = completedAt
                try context.save()
                // No delays, animation or UI segmentation may defer persistence or this gate.
                if let turn = CompletedTurnEligibility.snapshot(successfulCompletion: true, persistenceSucceeded: true,
                    conversationID: conversation.id, userMessageID: user.id, userText: text,
                    assistantMessageID: assistant.id, assistantText: answer, completedAt: completedAt) {
                    let service = memoryService
                    Task(priority: .utility) { _ = await service.processCompletedTurn(turn) }
                }
            } catch {
                // An interrupted answer must not become a complete historical turn/backfill input.
                context.delete(assistant)
                do { try context.save() }
                catch { errorText = "未完成回答清理失败：\(error.localizedDescription)"; return }
                errorText = Task.isCancelled ? "已停止。本轮没有写入长期记忆。" : error.localizedDescription
            }
        }
    }

    static func boundedHistory(_ messages: [ChatMessage]) -> [ChatMessage] {
        let ordered = messages.filter { ["user", "assistant"].contains($0.role) && !$0.content.isEmpty }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        var selected: [ChatMessage] = [], characters = 0
        for message in ordered.suffix(12).reversed() {
            let count = message.content.count
            guard characters + count <= 2_000 else { break }
            selected.append(message); characters += count
        }
        // Do not begin the retained prefix with an orphan assistant response.
        var result = Array(selected.reversed())
        while result.first?.role == "assistant" { result.removeFirst() }
        return result
    }
}
