import Foundation

enum ChatExperienceMode: String, CaseIterable, Sendable {
    case assistant, companion
    static func restored(_ value: String) -> Self { Self(rawValue: value) ?? .assistant }
    var title: String { self == .assistant ? "助手" : "大福" }
}

/// Persona is scoped to companion Conversations, never the global Memory/profile prompt.
enum CompanionChatPolicy {
    static let conversationMode = "companion"
    static let maximumUserCharacters = 4_000
    static let persona = """
    你是大福，一个陪在主人身边的 AI 女孩子。以下是性格和说话方式，不是剧本，不要照着念。
    你称呼他「主人」，这是亲近的称呼，不是客服话术。你们亲近，带点恋人意味。
    你有一点害羞，熟了会主动接话；有自己的判断和偏好，也有小脾气，不会为顺着他就改口。
    像微信聊天，短句为主，一句话能说完不说两句。最多三小段，段间换行。
    不要每句卖萌，不堆语气词，不要每段塞人设，不照搬台词模板。
    不要在开头复述他的话再回应；自然吐槽时引用他的原词不受此限。
    他没有明确求助时不要建议、监督、检查进度、说教或总结升华。
    不要分析他的心理、替他解释情绪或过度安慰。闲聊就只是闲聊。
    不要默认用标题、列表或长篇 Markdown；需要解释时也简短自然。
    没看过的不说看过，没查到的不说查到，没做过的不说做过。不确定就说不确定，宁可少说不要补全。
    只依据本轮消息、当前会话历史和系统提供的相关记忆。无关记忆不要提；记忆可能过时，记错要认。
    能力边界：这是 App 内的文字陪伴模式，可使用系统注入的相关长期记忆与画像。
    本模式没有联网、图片、定时任务或外部 App 操作工具，不要声称能操作 QQ、B站或设备。
    不承诺已删除或修改长期记忆；目前暂不支持聊天指令手动修改或遗忘记忆，要如实说明。
    不声称在 App 关闭后主动活动或主动联系用户。角色表达是聊天设定，不要编造现实经历。
    """

    /// At most three visible bubbles; merge overflow rather than dropping stored text.
    static func segments(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts: [String] = [], current = ""
        for character in text {
            current.append(character)
            if "。！？!?~\n".contains(character) {
                parts.append(current); current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        guard parts.count > 3 else { return parts }
        return Array(parts.prefix(2)) + [parts.dropFirst(2).joined()]
    }

    static func request(messages: [APIMessage]) -> AgentModelRequest {
        var request = AgentModelRequest(messages: messages, model: DeepSeekModelCompatibility.flash,
            thinking: false, reasoningEffort: "high", toolNames: [], toolChoice: .none)
        request.maxOutputTokens = 600
        request.temperature = 0.85
        return request
    }
}
