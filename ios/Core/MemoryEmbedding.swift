import CryptoKit
import Foundation
import NaturalLanguage

enum MemoryEmbeddingError: Error, Sendable, Equatable {
    case emptyText
    case providerUnavailable(String)
    case assetsUnavailable(String)
    case loadFailed(String)
    case embeddingFailed(String)
    case invalidVector
    case invalidEnvelope
}

struct MemoryEmbeddingDescriptor: Codable, Sendable, Equatable {
    let provider: String
    let modelIdentifier: String
    let revision: Int
    let dimension: Int
    let modelFamily: String
    let language: String
    let semantic: Bool
}

struct MemoryEmbeddingAvailability: Codable, Sendable, Equatable {
    let provider: String
    let modelIdentifier: String?
    let revision: Int?
    let dimension: Int?
    let modelFamily: String
    let language: String
    let semantic: Bool
    let hasAvailableAssets: Bool
    let loaded: Bool
    let detail: String
}

struct MemoryEmbeddingVector: Codable, Sendable, Equatable {
    let descriptor: MemoryEmbeddingDescriptor
    let values: [Float]

    init(descriptor: MemoryEmbeddingDescriptor, values: [Float]) throws {
        guard !values.isEmpty,
              values.count == descriptor.dimension,
              values.allSatisfy(\.isFinite)
        else { throw MemoryEmbeddingError.invalidVector }
        self.descriptor = descriptor
        self.values = values
    }
}

protocol MemoryEmbeddingProvider: Sendable {
    var providerIdentifier: String { get }
    var isSemantic: Bool { get }
    func availability(for text: String) async -> MemoryEmbeddingAvailability
    func embedding(for text: String) async throws -> MemoryEmbeddingVector
}

struct MemoryEmbeddingEnvelope: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let provider: String
    let modelIdentifier: String
    let revision: Int
    let dimension: Int
    let modelFamily: String
    let language: String
    let embeddedTextHash: String
    let vector: [Float]

    init(result: MemoryEmbeddingVector, text: String) {
        schemaVersion = Self.currentSchemaVersion
        provider = result.descriptor.provider
        modelIdentifier = result.descriptor.modelIdentifier
        revision = result.descriptor.revision
        dimension = result.descriptor.dimension
        modelFamily = result.descriptor.modelFamily
        language = result.descriptor.language
        embeddedTextHash = MemoryEmbeddingText.hash(text)
        vector = result.values
    }

    func isCurrent(for text: String, descriptor: MemoryEmbeddingDescriptor) -> Bool {
        schemaVersion == Self.currentSchemaVersion &&
        provider == descriptor.provider &&
        modelIdentifier == descriptor.modelIdentifier &&
        revision == descriptor.revision &&
        dimension == descriptor.dimension &&
        modelFamily == descriptor.modelFamily &&
        language == descriptor.language &&
        embeddedTextHash == MemoryEmbeddingText.hash(text) &&
        vector.count == dimension &&
        vector.allSatisfy(\.isFinite)
    }

    func encoded() throws -> Data {
        guard schemaVersion == Self.currentSchemaVersion,
              dimension > 0,
              vector.count == dimension,
              vector.allSatisfy(\.isFinite)
        else { throw MemoryEmbeddingError.invalidEnvelope }
        return try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> MemoryEmbeddingEnvelope {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == currentSchemaVersion,
              value.dimension > 0,
              value.vector.count == value.dimension,
              value.vector.allSatisfy(\.isFinite)
        else { throw MemoryEmbeddingError.invalidEnvelope }
        return value
    }
}

enum MemoryEmbeddingText {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(normalized(text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func language(for text: String) -> NLLanguage {
        if text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) { return .simplifiedChinese }
        if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return .japanese }
        if text.unicodeScalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { return .korean }
        return .english
    }
}

enum MemoryVectorMath {
    static func normalized(_ values: [Float]) -> [Float]? {
        let norm = sqrt(values.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return nil }
        return values.map { $0 / norm }
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        let leftNorm = sqrt(lhs.reduce(Float.zero) { $0 + $1 * $1 })
        let rightNorm = sqrt(rhs.reduce(Float.zero) { $0 + $1 * $1 })
        guard leftNorm > 0, rightNorm > 0 else { return nil }
        let dot = zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        let value = Double(dot / (leftNorm * rightNorm))
        return value.isFinite ? min(max(value, -1), 1) : nil
    }
}

actor NLSentenceMemoryEmbeddingProvider: MemoryEmbeddingProvider {
    nonisolated let providerIdentifier = "apple-nl-sentence"
    nonisolated let isSemantic = true
    private var models: [NLLanguage: NLEmbedding] = [:]

    func availability(for text: String) -> MemoryEmbeddingAvailability {
        let language = MemoryEmbeddingText.language(for: text)
        guard let model = model(for: language) else {
            return .init(
                provider: providerIdentifier, modelIdentifier: nil, revision: nil, dimension: nil,
                modelFamily: "NLEmbedding.sentence", language: language.rawValue, semantic: true,
                hasAvailableAssets: false, loaded: false, detail: "No sentence embedding for language"
            )
        }
        return .init(
            provider: providerIdentifier,
            modelIdentifier: "NLEmbedding.sentence.\(language.rawValue)",
            revision: 1,
            dimension: model.dimension,
            modelFamily: "NLEmbedding.sentence",
            language: language.rawValue,
            semantic: true,
            hasAvailableAssets: true,
            loaded: true,
            detail: "Bundled NaturalLanguage sentence embedding"
        )
    }

    func embedding(for text: String) throws -> MemoryEmbeddingVector {
        let normalizedText = MemoryEmbeddingText.normalized(text)
        guard !normalizedText.isEmpty else { throw MemoryEmbeddingError.emptyText }
        let language = MemoryEmbeddingText.language(for: normalizedText)
        guard let model = model(for: language) else {
            throw MemoryEmbeddingError.providerUnavailable(language.rawValue)
        }
        guard let raw = model.vector(for: normalizedText), !raw.isEmpty,
              let values = MemoryVectorMath.normalized(raw.map(Float.init))
        else { throw MemoryEmbeddingError.embeddingFailed(language.rawValue) }
        return try .init(
            descriptor: .init(
                provider: providerIdentifier,
                modelIdentifier: "NLEmbedding.sentence.\(language.rawValue)",
                revision: 1,
                dimension: values.count,
                modelFamily: "NLEmbedding.sentence",
                language: language.rawValue,
                semantic: true
            ),
            values: values
        )
    }

    private func model(for language: NLLanguage) -> NLEmbedding? {
        if let existing = models[language] { return existing }
        guard let value = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        models[language] = value
        return value
    }
}

@available(iOS 17.0, macOS 14.0, *)
actor NLContextualMemoryEmbeddingProvider: MemoryEmbeddingProvider {
    nonisolated let providerIdentifier = "apple-nl-contextual-mean"
    nonisolated let isSemantic = true

    private struct State {
        let model: NLContextualEmbedding
        var loaded: Bool
    }
    private var states: [NLLanguage: State] = [:]

    func availability(for text: String) -> MemoryEmbeddingAvailability {
        let language = MemoryEmbeddingText.language(for: text)
        guard let state = state(for: language) else {
            return .init(
                provider: providerIdentifier, modelIdentifier: nil, revision: nil, dimension: nil,
                modelFamily: "NLContextualEmbedding.meanPooling", language: language.rawValue, semantic: true,
                hasAvailableAssets: false, loaded: false, detail: "No contextual embedding for language"
            )
        }
        return .init(
            provider: providerIdentifier,
            modelIdentifier: state.model.modelIdentifier,
            revision: state.model.revision,
            dimension: state.model.dimension,
            modelFamily: "NLContextualEmbedding.meanPooling",
            language: language.rawValue,
            semantic: true,
            hasAvailableAssets: state.model.hasAvailableAssets,
            loaded: state.loaded,
            detail: "Mean pooling over every subword token, then L2 normalization"
        )
    }

    func prepare(for text: String, requestAssets: Bool) async -> MemoryEmbeddingAvailability {
        let language = MemoryEmbeddingText.language(for: text)
        guard var state = state(for: language) else { return availability(for: text) }
        if !state.model.hasAvailableAssets, requestAssets {
            _ = try? await requestAssets(for: state.model)
        }
        if state.model.hasAvailableAssets, !state.loaded {
            do {
                try state.model.load()
                state.loaded = true
                states[language] = state
            } catch {
                states[language] = state
            }
        }
        return availability(for: text)
    }

    func embedding(for text: String) throws -> MemoryEmbeddingVector {
        let normalizedText = MemoryEmbeddingText.normalized(text)
        guard !normalizedText.isEmpty else { throw MemoryEmbeddingError.emptyText }
        let language = MemoryEmbeddingText.language(for: normalizedText)
        guard var state = state(for: language) else {
            throw MemoryEmbeddingError.providerUnavailable(language.rawValue)
        }
        guard state.model.hasAvailableAssets else {
            throw MemoryEmbeddingError.assetsUnavailable(state.model.modelIdentifier)
        }
        if !state.loaded {
            do { try state.model.load() }
            catch { throw MemoryEmbeddingError.loadFailed(String(describing: error)) }
            state.loaded = true
            states[language] = state
        }
        let result: NLContextualEmbeddingResult
        do { result = try state.model.embeddingResult(for: normalizedText, language: language) }
        catch { throw MemoryEmbeddingError.embeddingFailed(String(describing: error)) }

        var sum = Array(repeating: Double.zero, count: state.model.dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: normalizedText.startIndex..<normalizedText.endIndex) { vector, _ in
            guard vector.count == sum.count else { return true }
            for index in vector.indices { sum[index] += vector[index] }
            tokenCount += 1
            return true
        }
        guard tokenCount > 0,
              let values = MemoryVectorMath.normalized(sum.map { Float($0 / Double(tokenCount)) })
        else { throw MemoryEmbeddingError.invalidVector }
        return try .init(
            descriptor: .init(
                provider: providerIdentifier,
                modelIdentifier: state.model.modelIdentifier,
                revision: state.model.revision,
                dimension: values.count,
                modelFamily: "NLContextualEmbedding.meanPooling",
                language: language.rawValue,
                semantic: true
            ),
            values: values
        )
    }

    private func state(for language: NLLanguage) -> State? {
        if let existing = states[language] { return existing }
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        let value = State(model: model, loaded: false)
        states[language] = value
        return value
    }

    private func requestAssets(for model: NLContextualEmbedding) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            model.requestAssets { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result == .available) }
            }
        }
    }
}

actor LexicalHashMemoryEmbeddingProvider: MemoryEmbeddingProvider {
    nonisolated let providerIdentifier = "local-feature-hash-v1"
    nonisolated let isSemantic = false
    nonisolated static let dimension = 128

    func availability(for text: String) -> MemoryEmbeddingAvailability {
        let language = MemoryEmbeddingText.language(for: text)
        return .init(
            provider: providerIdentifier,
            modelIdentifier: "sha256-token-feature-hash-128",
            revision: 1,
            dimension: Self.dimension,
            modelFamily: "lexical-feature-hash",
            language: language.rawValue,
            semantic: false,
            hasAvailableAssets: true,
            loaded: true,
            detail: "Deterministic unigram/bigram feature hashing; lexical fallback only, not semantic"
        )
    }

    func embedding(for text: String) throws -> MemoryEmbeddingVector {
        let normalizedText = MemoryEmbeddingText.normalized(text)
        guard !normalizedText.isEmpty else { throw MemoryEmbeddingError.emptyText }
        var tokens = normalizedText.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
        let cjk = normalizedText.filter { character in
            character.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        }
        tokens.append(contentsOf: cjk.map(String.init))
        let characters = Array(cjk)
        if characters.count > 1 {
            tokens.append(contentsOf: (0..<(characters.count - 1)).map { String([characters[$0], characters[$0 + 1]]) })
        }
        var vector = Array(repeating: Float.zero, count: Self.dimension)
        for token in tokens {
            let digest = Array(SHA256.hash(data: Data(token.utf8)))
            for offset in 0..<8 {
                let position = (Int(digest[offset * 2]) << 8 | Int(digest[offset * 2 + 1])) % Self.dimension
                vector[position] += digest[offset + 16].isMultiple(of: 2) ? -1 : 1
            }
        }
        guard let values = MemoryVectorMath.normalized(vector) else { throw MemoryEmbeddingError.invalidVector }
        return try .init(
            descriptor: .init(
                provider: providerIdentifier,
                modelIdentifier: "sha256-token-feature-hash-128",
                revision: 1,
                dimension: Self.dimension,
                modelFamily: "lexical-feature-hash",
                language: MemoryEmbeddingText.language(for: normalizedText).rawValue,
                semantic: false
            ),
            values: values
        )
    }
}
