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
    private let profileManager: UserProfileManager
    private let backfillCoordinator: MemoryBackfillCoordinator?

    init(store: MemoryStore, processor: MemoryProcessor, scanner: HistoricalTurnScanner? = nil) {
        self.store = store
        self.processor = processor
        retriever = MemoryRetriever(store: store)
        embeddingBackfill = MemoryEmbeddingBackfillService(store: store)
        chatReadPipeline = MemoryChatReadPipeline(retriever: retriever)
        let manager = UserProfileManager(store: store)
        profileManager = manager
        backfillCoordinator = scanner.map {
            MemoryBackfillCoordinator(scanner: $0, store: store, processor: processor, profileManager: manager)
        }
    }

    convenience init(modelContainer: ModelContainer, extractor: any MemoryExtracting = MemoryExtractionClient()) {
        let store = MemoryStore(modelContainer: modelContainer)
        self.init(
            store: store,
            processor: MemoryProcessor(store: store, extractor: extractor),
            scanner: HistoricalTurnScanner(modelContainer: modelContainer)
        )
    }

    func getUserProfile(scopeID: String = MemoryScope.localDefault) async throws -> UserMemoryProfileSnapshot {
        try await profileManager.profileSnapshot(scopeID: scopeID)
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

    /// O(1), fail-open chat read from the manager's in-memory ready snapshot. This method never
    /// scans MemoryItem storage and never waits for profile reconciliation.
    func readyProfileForChat(
        scopeID: String = MemoryScope.localDefault,
        now: Date = Date()
    ) async -> UserProfileChatSnapshot? {
        await profileManager.readyProfileForChat(scopeID: scopeID, now: now)
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
        let result = await processor.processCompletedTurn(turn)
        if case .processed(let operationCount, _) = result, operationCount > 0 {
            // Invalidate synchronously so chat can never observe a known-stale snapshot, then let
            // the manager own the low-priority refresh. The completed turn does not wait for it.
            await profileManager.markDirtyAndScheduleRefresh(scopeID: turn.scopeID)
        }
        return result
    }

    func historicalMemoryPreflight(
        scopeID: String = MemoryScope.localDefault
    ) async throws -> MemoryBackfillPreflight {
        guard let backfillCoordinator else { throw MemoryError.persistenceFailure("backfill_scanner_unavailable") }
        return try await backfillCoordinator.preflight(scopeID: scopeID)
    }

    func startHistoricalMemoryImport(
        scopeID: String = MemoryScope.localDefault,
        onProgress: (@Sendable (MemoryBackfillProgress) -> Void)? = nil
    ) async -> MemoryBackfillProgress {
        guard let backfillCoordinator else {
            return .init(state: .partiallyFailed, failed: 1)
        }
        return await backfillCoordinator.start(scopeID: scopeID, onProgress: onProgress)
    }

    func cancelHistoricalMemoryImport() async {
        await backfillCoordinator?.cancel()
    }

    func refreshUserProfileIfNeeded(
        scopeID: String = MemoryScope.localDefault,
        now: Date = Date()
    ) async {
        _ = try? await profileManager.refreshIfNeeded(scopeID: scopeID, now: now)
    }
}
