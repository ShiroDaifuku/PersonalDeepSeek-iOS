import Foundation
import Darwin

protocol ResearchDNSResolving: Sendable {
    func addresses(for host: String) async throws -> [String]
}

protocol ResearchHTTPFetching: Sendable {
    func data(for request: URLRequest) async throws -> ResearchHTTPResponse
}

struct ResearchHTTPResponse: Sendable {
    let data: Data
    let url: URL
    let statusCode: Int
    let headers: [String: String]

    init(data: Data, url: URL, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.url = url
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [String: String]()) { result, item in
            result[item.key.lowercased()] = item.value
        }
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

final class URLSessionResearchHTTPFetcher: ResearchHTTPFetching, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession) { self.session = session }

    func data(for request: URLRequest) async throws -> ResearchHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let url = http.url else {
            throw LocalResearchError.invalidPage
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let key = item.key as? String { result[key] = String(describing: item.value) }
        }
        return .init(data: data, url: url, statusCode: http.statusCode, headers: headers)
    }
}

final class ResearchNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum ResearchHTTPFetcherFactory {
    static func noRedirect(
        configuration: URLSessionConfiguration = .ephemeral
    ) -> URLSessionResearchHTTPFetcher {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: ResearchNoRedirectDelegate(),
            delegateQueue: nil
        )
        return URLSessionResearchHTTPFetcher(session: session)
    }
}

private final class DNSResolutionContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Error>?
    private var terminalResult: Result<[String], Error>?

    func install(_ continuation: CheckedContinuation<[String], Error>) {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<[String], Error>) {
        lock.lock()
        guard terminalResult == nil else { lock.unlock(); return }
        terminalResult = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

struct SystemResearchDNSResolver: ResearchDNSResolving, Sendable {
    let timeout: TimeInterval
    private let lookup: @Sendable (String) throws -> [String]

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
        lookup = { try Self.resolveSynchronously(host: $0) }
    }

    init(timeout: TimeInterval, lookup: @escaping @Sendable (String) throws -> [String]) {
        self.timeout = timeout
        self.lookup = lookup
    }

    func addresses(for host: String) async throws -> [String] {
        let state = DNSResolutionContinuation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                DispatchQueue.global(qos: .utility).async {
                    state.finish(Result { try lookup(host) })
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    state.finish(.failure(LocalResearchError.dnsResolutionTimedOut))
                }
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }

    private static func resolveSynchronously(host: String) throws -> [String] {
        var hints = addrinfo()
        // Ask for the complete A/AAAA set. AI_ADDRCONFIG can hide an answer that
        // URLSession may resolve later under a different interface state.
        hints.ai_flags = 0
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw LocalResearchError.dnsResolutionFailed
        }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ai_next
            guard entry.ai_family == AF_INET || entry.ai_family == AF_INET6,
                  let socketAddress = entry.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = buffer.withUnsafeMutableBufferPointer { pointer in
                getnameinfo(
                    socketAddress,
                    entry.ai_addrlen,
                    pointer.baseAddress,
                    socklen_t(pointer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
            guard result == 0 else { continue }
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
            addresses.append(String(decoding: bytes, as: UTF8.self))
        }
        let unique = Array(Set(addresses)).sorted()
        guard !unique.isEmpty else { throw LocalResearchError.dnsResolutionFailed }
        return unique
    }
}

enum ResearchIPPolicy {
    static func isPublicAddress(_ value: String) -> Bool {
        let address = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            return isPublicIPv4(UInt32(bigEndian: ipv4.s_addr))
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { raw in isPublicIPv6(Array(raw)) }
        }
        return false
    }

    static func isIPAddress(_ value: String) -> Bool {
        let address = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr(), ipv6 = in6_addr()
        return inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1
    }

    private static func isPublicIPv4(_ address: UInt32) -> Bool {
        func matches(_ network: UInt32, _ prefix: Int) -> Bool {
            let mask = prefix == 0 ? UInt32.zero : UInt32.max << (32 - prefix)
            return address & mask == network & mask
        }
        let blocked: [(UInt32, Int)] = [
            (0x00000000, 8),   // unspecified/current network
            (0x0A000000, 8),   // RFC1918
            (0x64400000, 10),  // shared address space
            (0x7F000000, 8),   // loopback
            (0xA9FE0000, 16),  // link-local
            (0xAC100000, 12),  // RFC1918
            (0xC0000000, 24),  // IETF protocol assignments
            (0xC0000200, 24),  // documentation
            (0xC0586300, 24),  // deprecated 6to4 relay anycast
            (0xC0A80000, 16),  // RFC1918
            (0xC6120000, 15),  // benchmark testing
            (0xC6336400, 24),  // documentation
            (0xCB007100, 24),  // documentation
            (0xE0000000, 4)    // multicast and reserved
        ]
        return !blocked.contains { matches($0.0, $0.1) }
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false } // unspecified
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false } // loopback
        if bytes[0] == 0xFF { return false } // multicast
        if bytes[0] & 0xFE == 0xFC { return false } // unique-local
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false } // link-local
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0xC0 { return false } // deprecated site-local
        if bytes[0...3].elementsEqual([0x20, 0x01, 0x0D, 0xB8]) { return false } // documentation
        let mappedPrefix = bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF
        if mappedPrefix {
            let ipv4 = bytes[12...15].reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
            return isPublicIPv4(ipv4)
        }
        return true
    }
}

struct ResearchURLPolicy: Sendable {
    let resolver: any ResearchDNSResolving

    func validate(_ url: URL) async throws -> URL {
        guard Self.hasAllowedShape(url), let rawHost = url.host else {
            throw LocalResearchError.unsafeURL
        }
        let host = Self.normalizedHost(rawHost)
        if ResearchIPPolicy.isIPAddress(host) {
            guard ResearchIPPolicy.isPublicAddress(host) else { throw LocalResearchError.unsafeURL }
        } else {
            let addresses = try await resolver.addresses(for: host)
            try Task.checkCancellation()
            guard !addresses.isEmpty, addresses.allSatisfy(ResearchIPPolicy.isPublicAddress) else {
                throw LocalResearchError.unsafeURL
            }
        }
        return url
    }

    static func hasAllowedShape(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let rawHost = url.host,
              !rawHost.isEmpty else { return false }
        let host = normalizedHost(rawHost)
        guard !host.isEmpty,
              host != "localhost", host != "localhost.localdomain",
              !host.hasSuffix(".localhost"), !host.hasSuffix(".local") else { return false }
        return !ResearchIPPolicy.isIPAddress(host) || ResearchIPPolicy.isPublicAddress(host)
    }

    private static func normalizedHost(_ rawHost: String) -> String {
        let unbracketed = rawHost.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return unbracketed.hasSuffix(".") ? String(unbracketed.dropLast()) : unbracketed
    }
}

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

enum ResearchProvider: String, Codable, Sendable {
    case brave
    case bingRSS = "bing_rss"
}

struct ResearchGatherResult: Sendable, Equatable {
    let providerUsed: ResearchProvider
    let sources: [ResearchSource]
}

enum LocalResearchError: LocalizedError, Sendable {
    case invalidQuery, searchFailed(Int), invalidPage, pageTooLarge, noResults
    case unsafeURL, dnsResolutionFailed, dnsResolutionTimedOut, tooManyRedirects, unsupportedContentType
    var errorDescription: String? {
        switch self {
        case .invalidQuery: "研究问题不能为空。"
        case .searchFailed(let status): "搜索服务返回 \(status)。"
        case .invalidPage: "来源网页地址或内容无效。"
        case .pageTooLarge: "来源网页过大，已跳过。"
        case .noResults: "没有获得可用的搜索来源。"
        case .unsafeURL: "来源网页地址不安全，已拒绝访问。"
        case .dnsResolutionFailed: "无法安全解析来源网页地址。"
        case .dnsResolutionTimedOut: "解析来源网页地址超时。"
        case .tooManyRedirects: "来源网页重定向次数过多。"
        case .unsupportedContentType: "来源不是受支持的网页或文本内容。"
        }
    }
}

final class LocalResearchService: Sendable {
    static let maximumRedirects = 5
    static let maximumPageBytes = 1_500_000
    static let maximumPageCharacters = 12_000

    private let searchFetcher: any ResearchHTTPFetching
    private let pageFetcher: any ResearchHTTPFetching
    private let urlPolicy: ResearchURLPolicy
    private let searchAPIKey: @Sendable () -> String?

    init(
        session: URLSession = .shared,
        resolver: any ResearchDNSResolving = SystemResearchDNSResolver(),
        searchFetcher: (any ResearchHTTPFetching)? = nil,
        pageFetcher: (any ResearchHTTPFetching)? = nil,
        searchAPIKey: @escaping @Sendable () -> String? = { KeychainStore.readSearchAPIKey() }
    ) {
        self.searchFetcher = searchFetcher ?? URLSessionResearchHTTPFetcher(session: session)
        self.pageFetcher = pageFetcher ?? ResearchHTTPFetcherFactory.noRedirect()
        urlPolicy = ResearchURLPolicy(resolver: resolver)
        self.searchAPIKey = searchAPIKey
    }

    func gather(query: String, limit: Int = 6) async throws -> [ResearchSource] {
        try await gatherWithMetadata(query: query, limit: limit).sources
    }

    func gatherWithMetadata(query: String, limit: Int = 6) async throws -> ResearchGatherResult {
        let searched = try await searchWithProvider(query: query, limit: limit)
        let rows = searched.sources
        let gathered = try await withThrowingTaskGroup(of: ResearchSource.self) { group in
            for row in rows {
                group.addTask {
                    do { return try await self.fetch(row) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return row }
                }
            }
            var values: [ResearchSource] = []
            for try await value in group { values.append(value) }
            try Task.checkCancellation()
            return values.sorted { lhs, rhs in
                guard let left = rows.firstIndex(where: { $0.id == lhs.id }), let right = rows.firstIndex(where: { $0.id == rhs.id }) else { return lhs.title < rhs.title }
                return left < right
            }
        }
        guard !gathered.isEmpty else { throw LocalResearchError.noResults }
        return ResearchGatherResult(providerUsed: searched.providerUsed, sources: gathered)
    }

    func search(query: String, limit: Int = 6) async throws -> [ResearchSource] {
        try await searchWithProvider(query: query, limit: limit).sources
    }

    private func searchWithProvider(query: String, limit: Int) async throws -> ResearchGatherResult {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 500 else { throw LocalResearchError.invalidQuery }
        if let key = searchAPIKey(), !key.isEmpty {
            do {
                let rows = try await braveSearch(query: value, limit: limit, key: key)
                if !rows.isEmpty { return .init(providerUsed: .brave, sources: rows) }
            }
            catch is CancellationError { throw CancellationError() }
            catch { /* Fall back to the no-key provider below. */ }
        }
        try Task.checkCancellation()
        return .init(providerUsed: .bingRSS, sources: try await bingRSSSearch(query: value, limit: limit))
    }

    private func braveSearch(query: String, limit: Int, key: String) async throws -> [ResearchSource] {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [.init(name: "q", value: query), .init(name: "count", value: String(max(1, min(limit, 10))))]
        var request = URLRequest(url: components.url!); request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        let response = try await searchFetcher.data(for: request)
        let data = response.data
        guard response.statusCode == 200 else { throw LocalResearchError.searchFailed(response.statusCode) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = root["web"] as? [String: Any], let results = web["results"] as? [[String: Any]] else { throw LocalResearchError.noResults }
        let rows = results.prefix(limit).compactMap { item -> ResearchSource? in
            guard let rawURL = item["url"] as? String, let url = URL(string: rawURL), Self.isAllowed(url) else { return nil }
            return .init(title: item["title"] as? String ?? url.host ?? rawURL, url: url, snippet: item["description"] as? String ?? "")
        }
        guard !rows.isEmpty else { throw LocalResearchError.noResults }
        return rows
    }

    private func bingRSSSearch(query: String, limit: Int) async throws -> [ResearchSource] {
        var components = URLComponents(string: "https://www.bing.com/search")!
        components.queryItems = [.init(name: "q", value: query), .init(name: "format", value: "rss"), .init(name: "count", value: String(max(1, min(limit, 10)))), .init(name: "setlang", value: "zh-Hans")]
        var request = URLRequest(url: components.url!); request.timeoutInterval = 20
        request.setValue("application/rss+xml, application/xml;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; DeepSeekPersonal/1.0)", forHTTPHeaderField: "User-Agent")
        let response = try await searchFetcher.data(for: request)
        let data = response.data
        guard response.statusCode == 200 else { throw LocalResearchError.searchFailed(response.statusCode) }
        let rows = Self.parseBingRSS(data).prefix(limit).compactMap { item -> ResearchSource? in
            guard let url = URL(string: item.link), Self.isAllowed(url) else { return nil }
            return .init(title: item.title.isEmpty ? url.host ?? item.link : item.title, url: url, snippet: Self.plainText(fromHTML: item.description))
        }
        guard !rows.isEmpty else { throw LocalResearchError.noResults }
        return Array(rows)
    }

    func fetch(_ source: ResearchSource) async throws -> ResearchSource {
        var currentURL = try await urlPolicy.validate(source.url)
        for redirectCount in 0...Self.maximumRedirects {
            try Task.checkCancellation()
            var request = URLRequest(url: currentURL); request.timeoutInterval = 25
            request.setValue("Mozilla/5.0 (iPhone; DeepSeekPersonal/1.0)", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,text/plain,application/json,application/xml;q=0.9", forHTTPHeaderField: "Accept")
            let response = try await pageFetcher.data(for: request)
            try Task.checkCancellation()
            if Self.isRedirect(response.statusCode) {
                guard redirectCount < Self.maximumRedirects,
                      let location = response.header("location"),
                      let destination = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
                    throw LocalResearchError.tooManyRedirects
                }
                currentURL = try await urlPolicy.validate(destination)
                continue
            }
            guard (200..<300).contains(response.statusCode) else { throw LocalResearchError.invalidPage }
            guard response.data.count <= Self.maximumPageBytes else { throw LocalResearchError.pageTooLarge }
            guard Self.isSupportedTextContentType(response.header("content-type"), data: response.data) else {
                throw LocalResearchError.unsupportedContentType
            }
            guard let html = String(data: response.data, encoding: .utf8) ?? String(data: response.data, encoding: .isoLatin1) else {
                throw LocalResearchError.invalidPage
            }
            let text = Self.plainText(fromHTML: html)
            guard !text.isEmpty else { throw LocalResearchError.invalidPage }
            return .init(
                id: source.id,
                title: source.title,
                url: currentURL,
                snippet: source.snippet,
                pageText: String(text.prefix(Self.maximumPageCharacters))
            )
        }
        throw LocalResearchError.tooManyRedirects
    }

    static func evidencePrompt(question: String, sources: [ResearchSource]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let fetchedAt = formatter.string(from: Date())
        let timezone = TimeZone.current.identifier
        let evidence = sources.enumerated().map { index, source in
            "[\(index + 1)] \(source.title)\nURL: \(source.url.absoluteString)\n\(source.snippet)\n\(source.pageText)"
        }.joined(separator: "\n\n")
        return """
        本轮联网工具已于 \(fetchedAt)（用户时区：\(timezone)）完成搜索和网页抓取。
        研究问题：\(question)

        请直接根据本轮搜索结果回答。明确区分事实与推断，在相关句末使用 [n] 引用，并在末尾列出来源标题及 URL。不要声称无法联网、没有搜索工具、需要用户另行提供网页，也不要把来源误称为用户提供。若来源不足，只说明具体缺少什么。

        \(evidence)
        """
    }

    static func isAllowed(_ url: URL) -> Bool {
        ResearchURLPolicy.hasAllowedShape(url)
    }

    static func isRedirect(_ statusCode: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(statusCode)
    }

    static func isSupportedTextContentType(_ rawValue: String?, data: Data) -> Bool {
        guard let rawValue else {
            return looksLikeUTF8Text(data)
        }
        let mime = rawValue.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if mime.hasPrefix("text/") { return true }
        return [
            "application/json", "application/ld+json", "application/xml",
            "application/rss+xml", "application/atom+xml", "application/xhtml+xml"
        ].contains(mime)
    }

    private static func looksLikeUTF8Text(_ data: Data) -> Bool {
        guard String(data: data, encoding: .utf8) != nil else { return false }
        if data.isEmpty { return true }
        let disallowedControls = data.reduce(into: 0) { count, byte in
            if byte == 0 || (byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D) {
                count += 1
            }
        }
        return Double(disallowedControls) / Double(data.count) < 0.01
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

    static func parseBingRSS(_ data: Data) -> [(title: String, link: String, description: String)] {
        let delegate = RSSDelegate(), parser = XMLParser(data: data)
        parser.delegate = delegate
        return parser.parse() ? delegate.items : []
    }
}

private final class RSSDelegate: NSObject, XMLParserDelegate {
    var items: [(title: String, link: String, description: String)] = []
    private var insideItem = false, element = "", value = "", title = "", link = "", descriptionText = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName.lowercased() == "item" { insideItem = true; title = ""; link = ""; descriptionText = "" }
        guard insideItem else { return }; element = elementName.lowercased(); value = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if insideItem { value += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if insideItem { switch name { case "title": title = value.trimmingCharacters(in: .whitespacesAndNewlines); case "link": link = value.trimmingCharacters(in: .whitespacesAndNewlines); case "description": descriptionText = value.trimmingCharacters(in: .whitespacesAndNewlines); default: break } }
        if name == "item" { insideItem = false; if !link.isEmpty { items.append((title, link, descriptionText)) } }
        element = ""; value = ""
    }
}
