import Foundation

/// Request-local admission only. Does not mutate persisted tool evidence or Memory.
enum ToolHistoryRelevance {
    private static let stop: Set<String> = [
        "考研", "数学一", "资料", "信息", "内容", "问题", "题目", "这个", "那个", "一下", "如何", "怎么", "可以", "帮我", "请问",
        "the", "and", "for", "with", "this", "that", "what", "how", "search", "please", "about", "api", "app", "ios", "https", "http", "com", "www"
    ]
    static func admits(_ record: ToolExecutionRecordSnapshot, current: String, previousUser: String?) -> Bool {
        let query = String(current.prefix(2000)).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        if ["不要参考之前", "不参考旧", "不要用之前", "不用之前", "ignore previous search"].contains(where: query.contains) { return false }
        if ["刚才", "刚刚", "之前", "上一轮"].contains(where: query.contains),
           ["任务", "提醒", "知识库"].contains(where: query.contains),
           record.toolName.contains("task") || record.toolName == "manage_local_knowledge" { return true }
        // Explicit temporal audit/reference must retain the existing future-turn tool awareness.
        if ["刚才搜", "刚刚搜", "之前搜", "刚才查", "之前查", "上一轮搜", "这些来源", "这些搜索结果", "上面的搜索结果", "刚才的结果", "刚才的搜索", "previous search", "did you search", "those sources"].contains(where: query.contains) {
            return ["web_search", "start_deep_search", "search_local_knowledge", "local_knowledge_search"].contains(record.toolName)
        }
        guard let data = record.resultData,
              let envelope = try? JSONDecoder.toolPersistence.decode(ToolResultEnvelope.self, from: data) else { return false }
        var candidate = record.query ?? ""
        switch envelope.payload {
        case .webSearch(let payload): candidate += " " + payload.sources.map { $0.title + " " + $0.snippet }.joined(separator: " ")
        case .localKnowledge(let payload): candidate += " " + String(payload.boundedContext.prefix(1200))
        case .actionPrepared: return false
        }
        if related(query, candidate) { return true }
        let followup = ["它", "这个结果", "这个结论", "这些", "那为什么", "继续解释", "继续讲", "explain that", "tell me more", "why is that"]
        if query.count <= 60, followup.contains(where: query.contains),
           !["改成", "改编", "换个问题", "另一道", "new topic"].contains(where: query.contains), let previousUser {
            return related(String(previousUser.prefix(2000)).lowercased(), candidate)
        }
        return false
    }
    private static func related(_ query: String, _ candidate: String) -> Bool {
        let lhs = features(query), rhs = features(candidate.lowercased())
        let shared = lhs.intersection(rhs)
        // One distinctive Latin entity/URL is sufficient; generic Chinese topic labels are not.
        if shared.contains(where: { $0.count >= 3 && $0.unicodeScalars.allSatisfy(\.isASCII) && $0.contains(where: \.isLetter) }) { return true }
        return shared.count >= 2 && Double(shared.count) / Double(max(1, lhs.count)) >= 0.12
    }
    private static func features(_ text: String) -> Set<String> {
        var normalized = text.lowercased()
        for generic in ["考研数学一", "考研数学", "研究生考试", "考研", "数学一"] {
            normalized = normalized.replacingOccurrences(of: generic, with: " ")
        }
        var result = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 && !stop.contains($0) })
        result.formUnion(normalized.split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }
            .map(String.init).filter { $0.count >= 2 && !stop.contains($0) })
        var run: [Character] = []
        func flush() {
            if run.count > 1 {
                for i in 0..<(run.count - 1) {
                    let pair = String(run[i...i + 1])
                    if !stop.contains(pair) { result.insert(pair) }
                }
            }
            run.removeAll(keepingCapacity: true)
        }
        for character in normalized {
            if character.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }) { run.append(character) }
            else { flush() }
        }
        flush()
        return result
    }
}
