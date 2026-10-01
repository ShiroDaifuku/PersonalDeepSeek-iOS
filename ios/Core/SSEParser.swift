import Foundation

enum StreamDelta: Equatable, Sendable {
    case reasoning(String), content(String), usage(Int), done
    case toolCall(ToolCallFragment), finishReason(String), detailedUsage(AgentUsage)
}

struct SSEParser {
    private var buffer = Data()
    private var dataLines: [String] = []
    mutating func append(_ data: Data) -> [StreamDelta] {
        buffer.append(data)
        var output: [StreamDelta] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]; buffer.removeSubrange(...newline)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.last == "\r" { line.removeLast() }
            consume(line, into: &output)
        }
        return output
    }
    mutating func appendLine(_ value: String) -> [StreamDelta] {
        var line = value
        if line.last == "\r" { line.removeLast() }
        var output: [StreamDelta] = []
        consume(line, into: &output)
        return output
    }
    mutating func appendEventLine(_ value: String) -> [StreamDelta] {
        var line = value
        if line.last == "\r" { line.removeLast() }
        guard !line.isEmpty, !line.hasPrefix(":"), line.hasPrefix("data:") else { return [] }
        dataLines.removeAll(keepingCapacity: true)
        dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        var output: [StreamDelta] = []
        flush(into: &output)
        return output
    }
    mutating func finish() -> [StreamDelta] {
        var output: [StreamDelta] = []; if !buffer.isEmpty { consume(String(decoding: buffer, as: UTF8.self), into: &output); buffer.removeAll() }; flush(into: &output); return output
    }
    private mutating func consume(_ line: String, into output: inout [StreamDelta]) {
        if line.isEmpty { flush(into: &output) }
        else if line.hasPrefix(":") { return }
        else if line.hasPrefix("data:") { dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
    }
    private mutating func flush(into output: inout [StreamDelta]) {
        guard !dataLines.isEmpty else { return }; let raw = dataLines.joined(separator: "\n"); dataLines.removeAll()
        if raw == "[DONE]" { output.append(.done); return }
        guard let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let choices = object["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any] {
            if let value = delta["reasoning_content"] as? String, !value.isEmpty { output.append(.reasoning(value)) }
            if let value = delta["content"] as? String, !value.isEmpty { output.append(.content(value)) }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let function = call["function"] as? [String: Any]
                    output.append(.toolCall(.init(index: call["index"] as? Int ?? -1,
                        id: call["id"] as? String, type: call["type"] as? String,
                        name: function?["name"] as? String, arguments: function?["arguments"] as? String)))
                }
            }
        }
        if let choices = object["choices"] as? [[String: Any]], let reason = choices.first?["finish_reason"] as? String {
            output.append(.finishReason(reason))
        }
        if let usage = object["usage"] as? [String: Any], let total = usage["total_tokens"] as? Int { output.append(.usage(total)) }
        if let usage = object["usage"] as? [String: Any], usage["prompt_tokens"] != nil {
            let details = usage["completion_tokens_details"] as? [String: Any]
            output.append(.detailedUsage(.init(promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                completionTokens: usage["completion_tokens"] as? Int ?? 0,
                reasoningTokens: details?["reasoning_tokens"] as? Int ?? 0,
                cacheHitTokens: usage["prompt_cache_hit_tokens"] as? Int ?? 0,
                cacheMissTokens: usage["prompt_cache_miss_tokens"] as? Int ?? 0)))
        }
    }
}
