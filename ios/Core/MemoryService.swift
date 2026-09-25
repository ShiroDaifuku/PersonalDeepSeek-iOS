import Foundation
import SwiftData

protocol MemoryServing: Sendable {
    func getUserProfile(scopeID: String) async throws -> UserMemoryProfileSnapshot
    func listMemories(scopeID: String) async throws -> [MemoryItemSnapshot]
    func memory(id: UUID, scopeID: String) async throws -> MemoryItemSnapshot?
}

final class MemoryService: MemoryServing, Sendable {
    private let store: MemoryStore

    init(modelContainer: ModelContainer) {
        store = MemoryStore(modelContainer: modelContainer)
    }

    func getUserProfile(scopeID: String = MemoryScope.localDefault) async throws -> UserMemoryProfileSnapshot {
        try await store.getOrCreateProfile(scopeID: scopeID)
    }

    func listMemories(scopeID: String = MemoryScope.localDefault) async throws -> [MemoryItemSnapshot] {
        try await store.listMemories(scopeID: scopeID)
    }

    func memory(id: UUID, scopeID: String = MemoryScope.localDefault) async throws -> MemoryItemSnapshot? {
        try await store.memory(id: id, scopeID: scopeID)
    }
}
