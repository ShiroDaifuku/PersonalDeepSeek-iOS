import Foundation

enum MemoryProcessingResult: Sendable, Equatable {
    case processed(operationCount: Int, metrics: MemoryExtractionMetrics)
    case noop(metrics: MemoryExtractionMetrics)
    case alreadyProcessed(status: MemoryTurnStatus)
    case failed(code: String)
}

actor MemoryProcessor {
    private let store: MemoryStore
    private let extractor: any MemoryExtracting

    init(store: MemoryStore, extractor: any MemoryExtracting) {
        self.store = store
        self.extractor = extractor
    }

    func processCompletedTurn(_ turn: CompletedTurnSnapshot) async -> MemoryProcessingResult {
        guard Self.isValid(turn) else { return .failed(code: MemoryProcessingError.invalidTurn.code) }
        do {
            if let record = try await store.turnRecord(processingKey: turn.processingKey),
               let status = record.status, status.isProcessed {
                return .alreadyProcessed(status: status)
            }

            let memories = try await store.listMemories(scopeID: turn.scopeID)
            let candidates = ExistingMemoryCandidateSelector.select(from: memories, for: turn.userText, now: turn.completedAt)
            let output = try await extractor.extract(turn: turn, candidates: candidates)
            let operations = try MemoryOperationValidator.validate(response: output.response, turn: turn, candidates: candidates)
            let applyResult = try await store.applyMemoryOperations(
                operations,
                for: turn,
                extractorVersion: MemoryExtractorPrompt.version,
                modelName: extractor.modelName,
                now: turn.completedAt
            )
            switch applyResult {
            case .alreadyProcessed(let record):
                return .alreadyProcessed(status: record.status ?? .failed)
            case .applied(let record, let mutationCount):
                if record.status == .noop { return .noop(metrics: output.metrics) }
                return .processed(operationCount: mutationCount, metrics: output.metrics)
            }
        } catch is CancellationError {
            return await recordFailure(turn, error: .networkError)
        } catch let error as MemoryProcessingError {
            return await recordFailure(turn, error: error)
        } catch {
            return await recordFailure(turn, error: .persistenceError)
        }
    }

    private func recordFailure(_ turn: CompletedTurnSnapshot, error: MemoryProcessingError) async -> MemoryProcessingResult {
        do {
            _ = try await store.recordFailedTurn(
                turn,
                extractorVersion: MemoryExtractorPrompt.version,
                modelName: extractor.modelName,
                errorCode: error.code
            )
            return .failed(code: error.code)
        } catch {
            return .failed(code: MemoryProcessingError.persistenceError.code)
        }
    }

    private static func isValid(_ turn: CompletedTurnSnapshot) -> Bool {
        let expected = CompletedTurnFingerprint.make(
            conversationID: turn.conversationID,
            userMessageID: turn.userMessageID,
            assistantMessageID: turn.assistantMessageID
        )
        return !turn.scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !turn.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !turn.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && turn.turnFingerprint == expected
    }
}
