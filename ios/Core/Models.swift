import Foundation
import SwiftData

@Model final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var systemPrompt: String
    var model: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation) var messages: [ChatMessage]
    init(title: String = "新对话", systemPrompt: String = "You are a helpful assistant.", model: String = "deepseek-flash") {
        id = UUID(); self.title = title; self.systemPrompt = systemPrompt; self.model = model; createdAt = Date(); messages = []
    }
}

@Model final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var role: String
    var content: String
    var reasoning: String
    var createdAt: Date
    var conversation: Conversation?
    init(role: String, content: String = "", reasoning: String = "", conversation: Conversation? = nil) {
        id = UUID(); self.role = role; self.content = content; self.reasoning = reasoning; createdAt = Date(); self.conversation = conversation
    }
}

struct APIMessage: Equatable, Sendable {
    let role: String
    let content: String
    let imageDataURLs: [String]

    init(role: String, content: String, imageDataURLs: [String] = []) {
        self.role = role
        self.content = content
        self.imageDataURLs = imageDataURLs
    }

    /// DeepSeek/OpenAI compatible message content. Plain messages keep the
    /// original string form; messages with images use multimodal content parts.
    var wireContent: Any {
        guard !imageDataURLs.isEmpty else { return content }
        var parts: [[String: Any]] = []
        if !content.isEmpty { parts.append(["type": "text", "text": content]) }
        parts.append(contentsOf: imageDataURLs.map { ["type": "image_url", "image_url": ["url": $0]] })
        return parts
    }
}

enum MessagePrefix {
    static func stable(system: String, history: [ChatMessage], newUserText: String, imageDataURLs: [String] = []) -> [APIMessage] {
        [.init(role: "system", content: system)] + history.sorted { lhs, rhs in lhs.createdAt == rhs.createdAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.createdAt < rhs.createdAt }.map { .init(role: $0.role, content: $0.content) } + [.init(role: "user", content: newUserText, imageDataURLs: imageDataURLs)]
    }
}
