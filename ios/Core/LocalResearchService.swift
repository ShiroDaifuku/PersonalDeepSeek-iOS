import Foundation

struct ResearchSource: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let url: URL
    let snippet: String
    let pageText: String
    init(id: UUID = UUID(), title: String, url: URL, snippet: String, pageText: String = "") {
        self.id = id; self.title = title; self.url = url; self.snippet = snippet; self.pageText = pageText
    }
}

enum LocalResearchError: LocalizedError, Sendable {
    case missingSearchKey, invalidQuery, searchFailed(Int), invalidPage, pageTooLarge, noResults
    var errorDescription: String? {
        switch self {
        case .missingSearchKey: "请先在设置中保存联网搜索 API Key。"
        case .invalidQuery: "研究问题不能为空。"
        case .searchFailed(let status): "搜索服务返回 \(status)。"
        case .invalidPage: "来源网页地址或内容无效。"
        case .pageTooLarge: "来源网页过大，已跳过。"
        case .noResults: "没有获得可用的搜索来源。"
        }
    }
}

final class LocalResearchService: Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func gather(query: String, limit: Int = 6) async throws -> [ResearchSource] {
        let rows = try await search(query: query, limit: limit)
        let gathered = await withTaskGroup(of: ResearchSource?.self) { group in
            for row in rows { group.addTask { try? await self.fetch(row) } }
            var values: [ResearchSource] = []
            for await value in group { if let value { values.append(value) } }
            return values.sorted { lhs, rhs in
                guard let left = rows.firstIndex(where: { $0.id == lhs.id }), let right = rows.firstIndex(where: { $0.id == rhs.id }) else { return lhs.title < rhs.title }
                return left < right
            }
        }
        guard !gathered.isEmpty else { throw LocalResearchError.noResults }
        return gathered
    }

    func search(query: String, limit: Int = 6) async throws -> [ResearchSource] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 500 else { throw LocalResearchError.invalidQuery }
        guard let key = KeychainStore.readSearchAPIKey(), !key.isEmpty else { throw LocalResearchError.missingSearchKey }
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [.init(name: "q", value: value), .init(name: "count", value: String(max(1, min(limit, 10))))]
        var request = URLRequest(url: components.url!); request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalResearchError.searchFailed(0) }
        guard http.statusCode == 200 else { throw LocalResearchError.searchFailed(http.statusCode) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = root["web"] as? [String: Any], let results = web["results"] as? [[String: Any]] else { throw LocalResearchError.noResults }
        let rows = results.prefix(limit).compactMap { item -> ResearchSource? in
            guard let rawURL = item["url"] as? String, let url = URL(string: rawURL), Self.isAllowed(url) else { return nil }
            return .init(title: item["title"] as? String ?? url.host ?? rawURL, url: url, snippet: item["description"] as? String ?? "")
        }
        guard !rows.isEmpty else { throw LocalResearchError.noResults }
        return rows
    }

    func fetch(_ source: ResearchSource) async throws -> ResearchSource {
        guard Self.isAllowed(source.url) else { throw LocalResearchError.invalidPage }
        var request = URLRequest(url: source.url); request.timeoutInterval = 25
        request.setValue("Mozilla/5.0 (iPhone; DeepSeekPersonal/1.0)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw LocalResearchError.invalidPage }
        guard data.count <= 1_500_000 else { throw LocalResearchError.pageTooLarge }
        let encoding = String.Encoding.utf8
        guard let html = String(data: data, encoding: encoding) else { throw LocalResearchError.invalidPage }
        let text = Self.plainText(fromHTML: html)
        guard !text.isEmpty else { throw LocalResearchError.invalidPage }
        return .init(id: source.id, title: source.title, url: source.url, snippet: source.snippet, pageText: String(text.prefix(12_000)))
    }

    static func evidencePrompt(question: String, sources: [ResearchSource]) -> String {
        let evidence = sources.enumerated().map { index, source in
            "[\(index + 1)] \(source.title)\nURL: \(source.url.absoluteString)\n\(source.snippet)\n\(source.pageText)"
        }.joined(separator: "\n\n")
        return "研究问题：\(question)\n\n请综合以下来源，明确区分事实与推断，并在相关句末使用 [n] 引用。最后列出仍不确定的问题。\n\n\(evidence)"
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return false }
        let blocked = ["127.", "10.", "192.168.", "169.254.", "0."]
        if blocked.contains(where: host.hasPrefix) { return false }
        return !host.hasPrefix("fc") && !host.hasPrefix("fd") && !host.hasPrefix("fe80:")
    }

    static func plainText(fromHTML html: String) -> String {
        var value = html
        for pattern in ["(?is)<script[^>]*>.*?</script>", "(?is)<style[^>]*>.*?</style>", "(?s)<[^>]+>"] {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, replacement) in entities { value = value.replacingOccurrences(of: entity, with: replacement) }
        return value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
