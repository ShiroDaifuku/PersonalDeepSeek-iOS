import Foundation

enum DeepSeekWebError: LocalizedError, Sendable, Equatable {
    case missingKey, invalidQuery, invalidURL, invalidResponse, responseTooLarge, http(Int)
    var errorDescription: String? {
        switch self {
        case .missingKey: "请在设置 → 网页搜索中保存 DeepSeek Key，或启用复用聊天 Key。"
        case .invalidQuery: "DeepSeek 搜索词需为 1–128 个字符，请缩短搜索词。"
        case .invalidURL: "网页地址必须是无账号密码的公开 HTTPS 地址。"
        case .invalidResponse: "DeepSeek 网页接口返回格式无效。"
        case .responseTooLarge: "DeepSeek 网页响应超过本地安全上限。"
        case .http(let status): "DeepSeek 网页接口返回 \(status)，请检查网页 Key 的权限、余额或服务状态。"
        }
    }
}

/// Ordinary interactive web tools only. ResearchRun and its admission/accounting
/// contracts deliberately keep using their existing LocalResearchService path.
struct DeepSeekWebService: Sendable {
    private let key: @Sendable () -> String?
    private let fetcher: any ResearchHTTPFetching
    init(key: @escaping @Sendable () -> String? = { ClientCredentials.resolvedWebKey() },
         fetcher: any ResearchHTTPFetching = ResearchHTTPFetcherFactory.noRedirect()) {
        self.key = key; self.fetcher = fetcher
    }

    func search(query: String, limit: Int = 3) async throws -> [ResearchSource] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 128 else { throw DeepSeekWebError.invalidQuery }
        let data = try await post("search", body: ["query": value, "count": max(1, min(3, limit)), "need_content": false])
        let decoded: SearchResponse
        do { decoded = try JSONDecoder().decode(SearchResponse.self, from: data) }
        catch { throw DeepSeekWebError.invalidResponse }
        return decoded.results.prefix(max(1, min(3, limit))).compactMap { row in
            guard let url = URL(string: row.url), LocalResearchService.isAllowed(url) else { return nil }
            let summary = row.summary?.isEmpty == false ? row.summary! : row.snippet
            return ResearchSource(title: String(row.title.prefix(500)), url: url,
                snippet: String(summary.prefix(1200)))
        }
    }

    func fetch(_ source: ResearchSource) async throws -> ResearchSource {
        guard source.url.absoluteString.count <= 8192, LocalResearchService.isAllowed(source.url) else {
            throw DeepSeekWebError.invalidURL
        }
        // Only the fixed official endpoint is contacted locally; no credentials
        // are sent to the third-party source and no local redirect is followed.
        let data = try await post("fetch", body: ["url": source.url.absoluteString])
        let page: FetchResponse
        do { page = try JSONDecoder().decode(FetchResponse.self, from: data) }
        catch { throw DeepSeekWebError.invalidResponse }
        guard !page.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekWebError.invalidResponse
        }
        return .init(id: source.id, title: source.title.isEmpty ? String(page.title.prefix(500)) : source.title,
            url: source.url, snippet: source.snippet, pageText: String(page.content.prefix(12_000)))
    }

    func gather(query: String, limit: Int = 3) async throws -> ResearchGatherResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            guard let url = URL(string: trimmed), !trimmed.contains(where: \.isWhitespace),
                  LocalResearchService.isAllowed(url) else { throw DeepSeekWebError.invalidURL }
            let source = try await fetch(.init(title: "", url: url, snippet: ""))
            return .init(providerUsed: .deepSeek, sources: [source])
        }
        let rows = try await search(query: query, limit: limit)
        var sources: [ResearchSource] = []
        // Sequential and at most three fetches: predictable charge/cancel boundary.
        for row in rows {
            try Task.checkCancellation()
            do { sources.append(try await fetch(row)) }
            catch is CancellationError { throw CancellationError() }
            catch let error as DeepSeekWebError {
                // Authentication/quota failures must not masquerade as success.
                if case .http(let status) = error, [401, 403, 429].contains(status) { throw error }
                sources.append(row)
            } catch { sources.append(row) }
        }
        return .init(providerUsed: .deepSeek, sources: sources)
    }

    private func post(_ operation: String, body: [String: Any]) async throws -> Data {
        guard let value = key(), !value.isEmpty else { throw DeepSeekWebError.missingKey }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/tools/\(operation)")!)
        request.httpMethod = "POST"; request.timeoutInterval = 35
        request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let response = try await fetcher.data(for: request)
            try Task.checkCancellation()
            guard response.data.count <= 1_500_000 else { throw DeepSeekWebError.responseTooLarge }
            if response.statusCode == 429 || (500...599).contains(response.statusCode), attempt < 2 {
                try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                continue
            }
            guard response.statusCode == 200 else { throw DeepSeekWebError.http(response.statusCode) }
            return response.data
        }
        throw DeepSeekWebError.invalidResponse
    }

    private struct SearchResponse: Decodable { let results: [Row] }
    private struct Row: Decodable { let title: String; let url: String; let snippet: String; let summary: String? }
    private struct FetchResponse: Decodable { let title: String; let content: String }
}

struct InteractiveWebService: Sendable {
    func gather(query: String, limit: Int) async throws -> ResearchGatherResult {
        switch ClientCredentials.webProvider() {
        case .deepSeek: try await DeepSeekWebService().gather(query: query, limit: limit)
        case .bing: try await LocalResearchService(searchAPIKey: { nil }).gatherWithMetadata(query: query, limit: limit)
        case .brave: try await LocalResearchService().gatherWithMetadata(query: query, limit: limit)
        }
    }
}
