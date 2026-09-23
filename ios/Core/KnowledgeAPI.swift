import Foundation

struct RemoteKnowledgeBase: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var enabled: Bool?
    let createdAt: String
    let updatedAt: String
    let documentIds: [String]
}

struct RemoteKnowledgeDocument: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mediaType: String
    let size: Int
    let createdAt: String
}

struct KnowledgeResult: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let knowledgeBaseId: String
    let documentId: String
    let documentName: String
    let index: Int
    let text: String
    let score: Double
}

private struct KnowledgeBasesEnvelope: Codable { let knowledgeBases: [RemoteKnowledgeBase] }
private struct KnowledgeBaseEnvelope: Codable { let knowledgeBase: RemoteKnowledgeBase }
private struct KnowledgeDocumentEnvelope: Codable { let document: RemoteKnowledgeDocument; let chunks: Int }
private struct KnowledgeDocumentsEnvelope: Codable { let documents: [RemoteKnowledgeDocument] }
private struct KnowledgeResultsEnvelope: Codable { let results: [KnowledgeResult] }

final class KnowledgeAPI: Sendable {
    let base: URL
    let userID: String
    init(base: URL, userID: String) { self.base = base; self.userID = userID }

    func list() async throws -> [RemoteKnowledgeBase] {
        try await call("v1/knowledge-bases", method: "GET", body: Optional<String>.none, as: KnowledgeBasesEnvelope.self).knowledgeBases
    }

    func create(name: String) async throws -> RemoteKnowledgeBase {
        try await call("v1/knowledge-bases", method: "POST", body: ["name": name], as: KnowledgeBaseEnvelope.self).knowledgeBase
    }

    func setEnabled(_ item: RemoteKnowledgeBase, enabled: Bool) async throws -> RemoteKnowledgeBase {
        try await call("v1/knowledge-bases/\(item.id)", method: "PATCH", body: ["enabled": enabled], as: KnowledgeBaseEnvelope.self).knowledgeBase
    }

    func upload(to knowledgeBase: RemoteKnowledgeBase, name: String, mediaType: String, data: Data) async throws -> RemoteKnowledgeDocument {
        struct Upload: Encodable { let name: String; let mediaType: String; let contentBase64: String }
        return try await call("v1/knowledge-bases/\(knowledgeBase.id)/files", method: "POST", body: Upload(name: name, mediaType: mediaType, contentBase64: data.base64EncodedString()), as: KnowledgeDocumentEnvelope.self).document
    }

    func files(in knowledgeBase: RemoteKnowledgeBase) async throws -> [RemoteKnowledgeDocument] {
        try await call("v1/knowledge-bases/\(knowledgeBase.id)/files", method: "GET", body: Optional<String>.none, as: KnowledgeDocumentsEnvelope.self).documents
    }

    func delete(document: RemoteKnowledgeDocument) async throws {
        var request = URLRequest(url: base.appending(path: "v1/documents/\(document.id)"))
        request.httpMethod = "DELETE"
        request.setValue(userID, forHTTPHeaderField: "X-User-ID")
        if let token = KeychainStore.readProxyToken(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidConfiguration }
        guard (200..<300).contains(http.statusCode) else {
            if let value = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) { throw NSError(domain: value.error.code, code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: value.error.message]) }
            throw ClientError.badResponse(http.statusCode)
        }
    }

    func query(_ text: String, knowledgeBaseID: String? = nil, limit: Int = 8) async throws -> [KnowledgeResult] {
        struct Query: Encodable { let query: String; let knowledgeBaseId: String?; let limit: Int }
        return try await call("v1/knowledge/query", method: "POST", body: Query(query: text, knowledgeBaseId: knowledgeBaseID, limit: limit), as: KnowledgeResultsEnvelope.self).results
    }

    private func call<T: Decodable, E: Encodable>(_ path: String, method: String, body: E?, as: T.Type) async throws -> T {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.setValue(userID, forHTTPHeaderField: "X-User-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = KeychainStore.readProxyToken(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidConfiguration }
        guard (200..<300).contains(http.statusCode) else {
            if let value = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) { throw NSError(domain: value.error.code, code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: value.error.message]) }
            throw ClientError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
