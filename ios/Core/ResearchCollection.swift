import Foundation

/// Host bounds for ephemeral, untrusted collection. No persistence or Memory input.
struct ResearchCollectionLimits: Equatable, Sendable {
    enum ValidationError: Error { case invalidLimits, invalidURL }
    let maxSources: Int
    let resultsPerQuery: Int
    let urlCharacters: Int
    let urlBytes: Int
    let textCharacters: Int
    let textBytes: Int

    init(maxSources: Int = 12, resultsPerQuery: Int = 6, urlCharacters: Int = 4_096,
         urlBytes: Int = 16_384, textCharacters: Int = 12_000, textBytes: Int = 48_000) throws {
        guard (1...64).contains(maxSources), (1...10).contains(resultsPerQuery),
              (1...8_192).contains(urlCharacters), (1...32_768).contains(urlBytes),
              (1...24_000).contains(textCharacters), (1...96_000).contains(textBytes) else {
            throw ValidationError.invalidLimits
        }
        self.maxSources = maxSources; self.resultsPerQuery = resultsPerQuery
        self.urlCharacters = urlCharacters; self.urlBytes = urlBytes
        self.textCharacters = textCharacters; self.textBytes = textBytes
    }

    func key(for url: URL) throws -> String {
        guard url.absoluteString.count <= urlCharacters, url.absoluteString.utf8.count <= urlBytes,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme, let host = parts.host else { throw ValidationError.invalidURL }
        parts.scheme = scheme.lowercased(); parts.host = host.lowercased(); parts.fragment = nil
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        guard let key = parts.string else { throw ValidationError.invalidURL }
        return key
    }

    func clipped(_ text: String) -> String {
        var bytes = 0, count = 0, result = ""
        for character in text {
            let value = String(character), size = value.utf8.count
            guard count < textCharacters, size <= textBytes - bytes else { break }
            result.append(character); bytes += size; count += 1
        }
        return result
    }
}

struct ResearchCollectedSource: Equatable, Sendable {
    let id: String
    let requestedURLKey: String
    var queryIDs: [String]
    let provider: ResearchProvider
    let source: ResearchSource
    let pageFetched: Bool

    /// Count every retained textual field, including host metadata and associations.
    var characterCost: Int {
        id.count + requestedURLKey.count + queryIDs.reduce(0) { $0 + $1.count } + provider.rawValue.count
        + source.title.count + source.url.absoluteString.count + source.snippet.count + source.pageText.count
    }
}

struct ResearchCollectionSnapshot: Equatable, Sendable {
    let runID: UUID
    let conversationID: UUID
    let sources: [ResearchCollectedSource]
}
