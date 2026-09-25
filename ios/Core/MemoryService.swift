import Foundation
import SwiftData

protocol MemoryServing: Sendable {
    func getUserProfile(scopeID: String) async throws -> UserMemoryProfileSnapshot
    func listMemories(scopeID: String) async throws -> [MemoryItemSnapshot]
    func memory(id: UUID, scopeID: String) async throws -> MemoryItemSnapshot?
    func searchRelevantMemories(_ input: MemoryRetrievalInput) async throws -> [MemoryRetrievalResult]
}

final class MemoryService: MemoryServing, Sendable {
    private let store: MemoryStore
    private let processor: MemoryProcessor
    private let retriever: MemoryRetriever
    private let embeddingBackfill: MemoryEmbeddingBackfillService

    init(store: MemoryStore, processor: MemoryProcessor) {
        self.store = store
        self.processor = processor
        retriever = MemoryRetriever(store: store)
        embeddingBackfill = MemoryEmbeddingBackfillService(store: store)
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

    func searchRelevantMemories(_ input: MemoryRetrievalInput) async throws -> [MemoryRetrievalResult] {
        try await retriever.search(input)
    }

    func backfillMemoryEmbeddings(scopeID: String = MemoryScope.localDefault) async -> MemoryEmbeddingBackfillReport {
        await embeddingBackfill.backfill(scopeID: scopeID)
    }

    func processCompletedTurn(_ turn: CompletedTurnSnapshot) async -> MemoryProcessingResult {
        await processor.processCompletedTurn(turn)
    }
}
