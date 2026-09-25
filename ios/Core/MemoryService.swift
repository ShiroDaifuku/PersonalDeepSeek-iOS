import Foundation
import SwiftData

protocol MemoryServing: Sendable {
    func getUserProfile(scopeID: String) async throws -> UserMemoryProfileSnapshot
    func listMemories(scopeID: String) async throws -> [MemoryItemSnapshot]
    func memory(id: UUID, scopeID: String) async throws -> MemoryItemSnapshot?
}

final class MemoryService: MemoryServing, Sendable {
    private let store: MemoryStore
    private let processor: MemoryProcessor

    init(store: MemoryStore, processor: MemoryProcessor) {
        self.store = store
        self.processor = processor
    }

    convenience init(modelContainer: ModelContainer, extractor: any MemoryExtracting = MemoryExtractionClient()) {
        let store = MemoryStore(modelContainer: modelContainer)
        self.init(store: store, processor: MemoryProcessor(store: store, extractor: extractor))
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

    func processCompletedTurn(_ turn: CompletedTurnSnapshot) async -> MemoryProcessingResult {
        await processor.processCompletedTurn(turn)
    }
}
