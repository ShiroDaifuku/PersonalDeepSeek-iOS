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
    private let chatReadPipeline: MemoryChatReadPipeline

    init(store: MemoryStore, processor: MemoryProcessor) {
        self.store = store
        self.processor = processor
        retriever = MemoryRetriever(store: store)
        embeddingBackfill = MemoryEmbeddingBackfillService(store: store)
        chatReadPipeline = MemoryChatReadPipeline(retriever: retriever)
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

    /// Fail-open request-time memory read. This never mutates chat or memory state and never
    /// surfaces an auxiliary retrieval failure to the normal chat error path.
    func contextForChat(
        input: MemoryRetrievalInput,
        currentUserText: String,
        now: Date = Date()
    ) async -> MemoryContextSnapshot? {
        let outcome = await chatReadPipeline.read(
            input: input,
            currentUserText: currentUserText,
            now: now
        )
#if DEBUG
        let injected = outcome.context?.injected.map {
            "\($0.id.uuidString):\($0.kind.rawValue):rank=\($0.rank):score=\(String(format: "%.3f", $0.finalScore))"
        }.joined(separator: ",") ?? "none"
        let suppressed = outcome.suppressed.map { "\($0.id.uuidString):\($0.reason.rawValue)" }
            .joined(separator: ",")
        print(
            "[MemoryRead] status=\(outcome.status.rawValue) retrieval_ms=\(outcome.retrievalMilliseconds) " +
            "build_ms=\(outcome.contextBuildMilliseconds) results=\(outcome.retrievedCount) " +
            "injected=[\(injected)] suppressed=[\(suppressed)] " +
            "chars=\(outcome.context?.characterCount ?? 0) tokens_est=\(outcome.context?.estimatedTokens ?? 0)"
        )
#endif
        return outcome.context
    }

    /// Optional low-priority preparation. Retrieval never waits for this operation: until the
    /// provider is fully ready, the resolver immediately uses lexical/entity fallback.
    func prepareSemanticProviderIfAvailable() async {
        await retriever.prepareSemanticProviderIfAvailable(for: "用户偏好与正在进行的项目")
    }

    func backfillMemoryEmbeddings(scopeID: String = MemoryScope.localDefault) async -> MemoryEmbeddingBackfillReport {
        await embeddingBackfill.backfill(scopeID: scopeID)
    }

    func processCompletedTurn(_ turn: CompletedTurnSnapshot) async -> MemoryProcessingResult {
        await processor.processCompletedTurn(turn)
    }
}
