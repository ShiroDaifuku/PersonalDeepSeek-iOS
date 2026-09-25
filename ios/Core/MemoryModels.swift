import CryptoKit
import Foundation
import SwiftData

enum MemoryScope {
    static let localDefault = "local-default"
}

enum MemoryKind: String, Codable, Sendable, CaseIterable {
    case durableFact
    case preference
    case ongoingContext
    case recentState
    case event
    case other
}

enum MemoryStatus: String, Codable, Sendable, CaseIterable {
    case active
    case superseded
    case invalidated
}

enum MemoryScore {
    static let defaultImportance = 0.5
    static let defaultConfidence = 0.5

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

struct UserMemoryProfilePayload: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var durable: [String]
    var preferences: [String]
    var ongoing: [String]
    var recentState: [String]
    var recentFocus: [String]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        durable: [String] = [],
        preferences: [String] = [],
        ongoing: [String] = [],
        recentState: [String] = [],
        recentFocus: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.durable = durable
        self.preferences = preferences
        self.ongoing = ongoing
        self.recentState = recentState
        self.recentFocus = recentFocus
    }

    static let empty = UserMemoryProfilePayload()
}

@Model final class UserMemoryProfile {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var scopeID: String
    var profileData: Data
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        scopeID: String,
        profileData: Data,
        revision: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.scopeID = scopeID
        self.profileData = profileData
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model final class MemoryItem {
    @Attribute(.unique) var id: UUID
    var scopeID: String
    var kindRawValue: String
    var canonicalText: String
    var embeddingData: Data?
    var importance: Double
    var confidence: Double
    var statusRawValue: String
    var createdAt: Date
    var updatedAt: Date
    var lastReinforcedAt: Date?
    var expiresAt: Date?
    var reinforcementCount: Int
    @Relationship(deleteRule: .cascade, inverse: \MemorySource.memoryItem) var sources: [MemorySource]

    init(
        id: UUID = UUID(),
        scopeID: String,
        kindRawValue: String,
        canonicalText: String,
        embeddingData: Data? = nil,
        importance: Double = MemoryScore.defaultImportance,
        confidence: Double = MemoryScore.defaultConfidence,
        statusRawValue: String = MemoryStatus.active.rawValue,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastReinforcedAt: Date? = nil,
        expiresAt: Date? = nil,
        reinforcementCount: Int = 0,
        sources: [MemorySource] = []
    ) {
        self.id = id
        self.scopeID = scopeID
        self.kindRawValue = kindRawValue
        self.canonicalText = canonicalText
        self.embeddingData = embeddingData
        self.importance = MemoryScore.clamped(importance)
        self.confidence = MemoryScore.clamped(confidence)
        self.statusRawValue = statusRawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastReinforcedAt = lastReinforcedAt
        self.expiresAt = expiresAt
        self.reinforcementCount = max(0, reinforcementCount)
        self.sources = sources
    }
}

@Model final class MemorySource {
    @Attribute(.unique) var id: UUID
    var scopeID: String
    var sourceConversationID: UUID
    var userMessageID: UUID?
    var assistantMessageID: UUID?
    var turnFingerprint: String
    var createdAt: Date
    var memoryItem: MemoryItem?

    init(
        id: UUID = UUID(),
        scopeID: String,
        sourceConversationID: UUID,
        userMessageID: UUID? = nil,
        assistantMessageID: UUID? = nil,
        turnFingerprint: String,
        createdAt: Date = Date(),
        memoryItem: MemoryItem? = nil
    ) {
        self.id = id
        self.scopeID = scopeID
        self.sourceConversationID = sourceConversationID
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.turnFingerprint = turnFingerprint
        self.createdAt = createdAt
        self.memoryItem = memoryItem
    }
}

struct UserMemoryProfileSnapshot: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let scopeID: String
    let payload: UserMemoryProfilePayload
    let revision: Int
    let createdAt: Date
    let updatedAt: Date
}

struct MemoryItemSnapshot: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let scopeID: String
    let kindRawValue: String
    let canonicalText: String
    let embeddingData: Data?
    let importance: Double
    let confidence: Double
    let statusRawValue: String
    let createdAt: Date
    let updatedAt: Date
    let lastReinforcedAt: Date?
    let expiresAt: Date?
    let reinforcementCount: Int

    var kind: MemoryKind { MemoryKind(rawValue: kindRawValue) ?? .other }
    var status: MemoryStatus? { MemoryStatus(rawValue: statusRawValue) }
}

struct MemorySourceSnapshot: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let scopeID: String
    let memoryItemID: UUID
    let sourceConversationID: UUID
    let userMessageID: UUID?
    let assistantMessageID: UUID?
    let turnFingerprint: String
    let createdAt: Date
}

struct MemoryItemDraft: Sendable, Equatable {
    var id: UUID
    var kind: MemoryKind
    var canonicalText: String
    var embeddingData: Data?
    var importance: Double
    var confidence: Double
    var status: MemoryStatus
    var createdAt: Date
    var updatedAt: Date
    var lastReinforcedAt: Date?
    var expiresAt: Date?
    var reinforcementCount: Int

    init(
        id: UUID = UUID(),
        kind: MemoryKind,
        canonicalText: String,
        embeddingData: Data? = nil,
        importance: Double = MemoryScore.defaultImportance,
        confidence: Double = MemoryScore.defaultConfidence,
        status: MemoryStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastReinforcedAt: Date? = nil,
        expiresAt: Date? = nil,
        reinforcementCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.canonicalText = canonicalText
        self.embeddingData = embeddingData
        self.importance = MemoryScore.clamped(importance)
        self.confidence = MemoryScore.clamped(confidence)
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastReinforcedAt = lastReinforcedAt
        self.expiresAt = expiresAt
        self.reinforcementCount = max(0, reinforcementCount)
    }
}

struct MemorySourceDraft: Sendable, Equatable {
    var id: UUID
    var sourceConversationID: UUID
    var userMessageID: UUID?
    var assistantMessageID: UUID?
    var turnFingerprint: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sourceConversationID: UUID,
        userMessageID: UUID? = nil,
        assistantMessageID: UUID? = nil,
        turnFingerprint: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceConversationID = sourceConversationID
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.turnFingerprint = turnFingerprint
        self.createdAt = createdAt
    }
}

enum CompletedTurnFingerprint {
    static func make(conversationID: UUID, userMessageID: UUID, assistantMessageID: UUID) -> String {
        let canonical = [
            "v1",
            conversationID.uuidString.lowercased(),
            userMessageID.uuidString.lowercased(),
            assistantMessageID.uuidString.lowercased()
        ].joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
