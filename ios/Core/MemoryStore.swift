import Foundation
import SwiftData

enum MemoryError: LocalizedError, Sendable, Equatable {
    case invalidScope
    case profileNotFound
    case memoryNotFound
    case invalidMemoryItem
    case invalidSource
    case encodingFailure
    case decodingFailure
    case revisionConflict(expected: Int, actual: Int)
    case persistenceFailure(String)
    case corruptData(String)

    var errorDescription: String? {
        switch self {
        case .invalidScope: "Memory scope is invalid."
        case .profileNotFound: "Memory profile was not found."
        case .memoryNotFound: "Memory item was not found."
        case .invalidMemoryItem: "Memory item is invalid."
        case .invalidSource: "Memory source is invalid."
        case .encodingFailure: "Memory profile could not be encoded."
        case .decodingFailure: "Memory profile could not be decoded."
        case .revisionConflict(let expected, let actual): "Memory profile revision conflict: expected \(expected), actual \(actual)."
        case .persistenceFailure(let detail): "Memory persistence failed: \(detail)"
        case .corruptData(let detail): "Memory data is corrupt: \(detail)"
        }
    }
}

@ModelActor
actor MemoryStore {
    func getOrCreateProfile(scopeID: String) throws -> UserMemoryProfileSnapshot {
        let scope = try validatedScope(scopeID)
        if let existing = try profileModel(scopeID: scope) { return try profileSnapshot(existing) }
        let now = Date()
        let data = try encodeProfile(.empty)
        let profile = UserMemoryProfile(scopeID: scope, profileData: data, createdAt: now, updatedAt: now)
        modelContext.insert(profile)
        try save()
        return try profileSnapshot(profile)
    }

    func profile(scopeID: String) throws -> UserMemoryProfileSnapshot? {
        let scope = try validatedScope(scopeID)
        guard let profile = try profileModel(scopeID: scope) else { return nil }
        return try profileSnapshot(profile)
    }

    func updateProfile(
        scopeID: String,
        expectedRevision: Int,
        payload: UserMemoryProfilePayload
    ) throws -> UserMemoryProfileSnapshot {
        let scope = try validatedScope(scopeID)
        guard let profile = try profileModel(scopeID: scope) else { throw MemoryError.profileNotFound }
        guard profile.revision == expectedRevision else {
            throw MemoryError.revisionConflict(expected: expectedRevision, actual: profile.revision)
        }
        profile.profileData = try encodeProfile(payload)
        profile.revision += 1
        profile.updatedAt = Date()
        try save()
        return try profileSnapshot(profile)
    }

    func insertMemory(scopeID: String, draft: MemoryItemDraft) throws -> MemoryItemSnapshot {
        let scope = try validatedScope(scopeID)
        let text = draft.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MemoryError.invalidMemoryItem }
        if try memoryModel(id: draft.id, scopeID: scope) != nil { throw MemoryError.invalidMemoryItem }
        let item = MemoryItem(
            id: draft.id,
            scopeID: scope,
            kindRawValue: draft.kind.rawValue,
            canonicalText: text,
            embeddingData: draft.embeddingData,
            importance: draft.importance,
            confidence: draft.confidence,
            statusRawValue: draft.status.rawValue,
            createdAt: draft.createdAt,
            updatedAt: draft.updatedAt,
            lastReinforcedAt: draft.lastReinforcedAt,
            expiresAt: draft.expiresAt,
            reinforcementCount: draft.reinforcementCount
        )
        modelContext.insert(item)
        try save()
        return memorySnapshot(item)
    }

    func memory(id: UUID, scopeID: String) throws -> MemoryItemSnapshot? {
        let scope = try validatedScope(scopeID)
        return try memoryModel(id: id, scopeID: scope).map(memorySnapshot)
    }

    func listMemories(scopeID: String) throws -> [MemoryItemSnapshot] {
        let scope = try validatedScope(scopeID)
        let requestedScope = scope
        let descriptor = FetchDescriptor<MemoryItem>(
            predicate: #Predicate { $0.scopeID == requestedScope },
            sortBy: [SortDescriptor(\MemoryItem.updatedAt, order: .reverse)]
        )
        return try fetch(descriptor).map(memorySnapshot)
    }

    func updateMemory(_ snapshot: MemoryItemSnapshot) throws -> MemoryItemSnapshot {
        let scope = try validatedScope(snapshot.scopeID)
        let text = snapshot.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MemoryError.invalidMemoryItem }
        guard let item = try memoryModel(id: snapshot.id, scopeID: scope) else { throw MemoryError.memoryNotFound }
        item.kindRawValue = snapshot.kindRawValue
        item.canonicalText = text
        item.embeddingData = snapshot.embeddingData
        item.importance = MemoryScore.clamped(snapshot.importance)
        item.confidence = MemoryScore.clamped(snapshot.confidence)
        item.statusRawValue = snapshot.statusRawValue
        item.updatedAt = snapshot.updatedAt
        item.lastReinforcedAt = snapshot.lastReinforcedAt
        item.expiresAt = snapshot.expiresAt
        item.reinforcementCount = max(0, snapshot.reinforcementCount)
        try save()
        return memorySnapshot(item)
    }

    @discardableResult
    func deleteMemory(id: UUID, scopeID: String) throws -> Bool {
        let scope = try validatedScope(scopeID)
        guard let item = try memoryModel(id: id, scopeID: scope) else { return false }
        modelContext.delete(item)
        try save()
        return true
    }

    func addSource(memoryItemID: UUID, scopeID: String, draft: MemorySourceDraft) throws -> MemorySourceSnapshot {
        let scope = try validatedScope(scopeID)
        let fingerprint = draft.turnFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty else { throw MemoryError.invalidSource }
        guard let item = try memoryModel(id: memoryItemID, scopeID: scope) else { throw MemoryError.memoryNotFound }
        let source = MemorySource(
            id: draft.id,
            scopeID: scope,
            sourceConversationID: draft.sourceConversationID,
            userMessageID: draft.userMessageID,
            assistantMessageID: draft.assistantMessageID,
            turnFingerprint: fingerprint,
            createdAt: draft.createdAt,
            memoryItem: nil
        )
        item.sources.append(source)
        modelContext.insert(source)
        try save()
        return sourceSnapshot(source, memoryItemID: item.id)
    }

    func sources(memoryItemID: UUID, scopeID: String) throws -> [MemorySourceSnapshot] {
        let scope = try validatedScope(scopeID)
        let requestedScope = scope
        let descriptor = FetchDescriptor<MemorySource>(
            predicate: #Predicate { $0.scopeID == requestedScope },
            sortBy: [SortDescriptor(\MemorySource.createdAt)]
        )
        return try fetch(descriptor).compactMap { source in
            guard let itemID = source.memoryItem?.id, itemID == memoryItemID else { return nil }
            return sourceSnapshot(source, memoryItemID: itemID)
        }
    }

    func updateSource(_ snapshot: MemorySourceSnapshot) throws -> MemorySourceSnapshot {
        let scope = try validatedScope(snapshot.scopeID)
        let fingerprint = snapshot.turnFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty else { throw MemoryError.invalidSource }
        guard let source = try sourceModel(id: snapshot.id, scopeID: scope) else {
            throw MemoryError.invalidSource
        }
        guard source.memoryItem?.id == snapshot.memoryItemID else {
            throw MemoryError.invalidSource
        }
        source.sourceConversationID = snapshot.sourceConversationID
        source.userMessageID = snapshot.userMessageID
        source.assistantMessageID = snapshot.assistantMessageID
        source.turnFingerprint = fingerprint
        source.createdAt = snapshot.createdAt
        try save()
        return sourceSnapshot(source, memoryItemID: snapshot.memoryItemID)
    }

    @discardableResult
    func deleteSource(id: UUID, scopeID: String) throws -> Bool {
        let scope = try validatedScope(scopeID)
        let requestedID = id
        let requestedScope = scope
        var descriptor = FetchDescriptor<MemorySource>(predicate: #Predicate {
            $0.id == requestedID && $0.scopeID == requestedScope
        })
        descriptor.fetchLimit = 1
        guard let source = try fetch(descriptor).first else { return false }
        modelContext.delete(source)
        try save()
        return true
    }

    func hasProcessedTurn(scopeID: String, turnFingerprint: String) throws -> Bool {
        let scope = try validatedScope(scopeID)
        let fingerprint = turnFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty else { throw MemoryError.invalidSource }
        let requestedScope = scope
        let requestedFingerprint = fingerprint
        var descriptor = FetchDescriptor<MemorySource>(predicate: #Predicate {
            $0.scopeID == requestedScope && $0.turnFingerprint == requestedFingerprint
        })
        descriptor.fetchLimit = 1
        return try !fetch(descriptor).isEmpty
    }

    private func validatedScope(_ scopeID: String) throws -> String {
        let value = scopeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 128 else { throw MemoryError.invalidScope }
        return value
    }

    private func profileModel(scopeID: String) throws -> UserMemoryProfile? {
        let requestedScope = scopeID
        var descriptor = FetchDescriptor<UserMemoryProfile>(predicate: #Predicate { $0.scopeID == requestedScope })
        descriptor.fetchLimit = 2
        let values = try fetch(descriptor)
        guard values.count <= 1 else { throw MemoryError.corruptData("duplicate profile scope") }
        return values.first
    }

    private func memoryModel(id: UUID, scopeID: String) throws -> MemoryItem? {
        let requestedID = id
        let requestedScope = scopeID
        var descriptor = FetchDescriptor<MemoryItem>(predicate: #Predicate {
            $0.id == requestedID && $0.scopeID == requestedScope
        })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func sourceModel(id: UUID, scopeID: String) throws -> MemorySource? {
        let requestedID = id
        let requestedScope = scopeID
        var descriptor = FetchDescriptor<MemorySource>(predicate: #Predicate {
            $0.id == requestedID && $0.scopeID == requestedScope
        })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func profileSnapshot(_ profile: UserMemoryProfile) throws -> UserMemoryProfileSnapshot {
        let payload: UserMemoryProfilePayload
        do { payload = try JSONDecoder().decode(UserMemoryProfilePayload.self, from: profile.profileData) }
        catch { throw MemoryError.decodingFailure }
        guard payload.schemaVersion > 0 else { throw MemoryError.corruptData("invalid profile payload schema version") }
        return .init(
            id: profile.id,
            scopeID: profile.scopeID,
            payload: payload,
            revision: profile.revision,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt
        )
    }

    private func memorySnapshot(_ item: MemoryItem) -> MemoryItemSnapshot {
        .init(
            id: item.id,
            scopeID: item.scopeID,
            kindRawValue: item.kindRawValue,
            canonicalText: item.canonicalText,
            embeddingData: item.embeddingData,
            importance: item.importance,
            confidence: item.confidence,
            statusRawValue: item.statusRawValue,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            lastReinforcedAt: item.lastReinforcedAt,
            expiresAt: item.expiresAt,
            reinforcementCount: item.reinforcementCount
        )
    }

    private func sourceSnapshot(_ source: MemorySource, memoryItemID: UUID) -> MemorySourceSnapshot {
        .init(
            id: source.id,
            scopeID: source.scopeID,
            memoryItemID: memoryItemID,
            sourceConversationID: source.sourceConversationID,
            userMessageID: source.userMessageID,
            assistantMessageID: source.assistantMessageID,
            turnFingerprint: source.turnFingerprint,
            createdAt: source.createdAt
        )
    }

    private func encodeProfile(_ payload: UserMemoryProfilePayload) throws -> Data {
        do { return try JSONEncoder().encode(payload) }
        catch { throw MemoryError.encodingFailure }
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        do { return try modelContext.fetch(descriptor) }
        catch { throw MemoryError.persistenceFailure(error.localizedDescription) }
    }

    private func save() throws {
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw MemoryError.persistenceFailure(error.localizedDescription) }
    }
}
