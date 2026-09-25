import Foundation

enum StreamDelta: Equatable, Sendable { case reasoning(String), content(String), usage(Int), done }

struct SSEParser {
    private var buffer = Data()
    private var dataLines: [String] = []
    mutating func append(_ data: Data) -> [StreamDelta] {
        buffer.append(data)
        var output: [StreamDelta] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[..<newline]; buffer.removeSubrange(...newline)
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
        }
        if let usage = object["usage"] as? [String: Any], let total = usage["total_tokens"] as? Int { output.append(.usage(total)) }
    }
}
