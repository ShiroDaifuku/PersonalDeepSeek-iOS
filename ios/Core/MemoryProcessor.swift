import Foundation

enum MemoryProcessingResult: Sendable, Equatable {
    case processed(operationCount: Int, metrics: MemoryExtractionMetrics)
    case noop(metrics: MemoryExtractionMetrics)
    case alreadyProcessed(status: MemoryTurnStatus)
    case failed(code: String)
}

struct MemoryProcessingDetails: Sendable, Equatable {
    let result: MemoryProcessingResult
    let skippedExpiredEphemeral: Int
    let skippedTemporalConflict: Int
}

actor MemoryProcessor {
    private let store: MemoryStore
    private let extractor: any MemoryExtracting

    init(store: MemoryStore, extractor: any MemoryExtracting) {
        self.store = store
        self.extractor = extractor
    }

    func processCompletedTurn(_ turn: CompletedTurnSnapshot) async -> MemoryProcessingResult {
        await processCompletedTurnDetailed(turn).result
    }

    func processCompletedTurnDetailed(_ turn: CompletedTurnSnapshot) async -> MemoryProcessingDetails {
        guard Self.isValid(turn) else {
            return .init(
                result: .failed(code: MemoryProcessingError.invalidTurn.code),
                skippedExpiredEphemeral: 0,
                skippedTemporalConflict: 0
            )
        }
        do {
            if let record = try await store.turnRecord(processingKey: turn.processingKey),
               let status = record.status, status.isProcessed {
                return .init(result: .alreadyProcessed(status: status), skippedExpiredEphemeral: 0, skippedTemporalConflict: 0)
            }

            let memories = try await store.listMemories(scopeID: turn.scopeID)
            let selectionTime = turn.origin == .historicalBackfill ? Date() : turn.completedAt
            let candidates = ExistingMemoryCandidateSelector.select(from: memories, for: turn.userText, now: selectionTime)
            let output = try await extractor.extract(turn: turn, candidates: candidates)
            let validated = try MemoryOperationValidator.validate(response: output.response, turn: turn, candidates: candidates)
            let guarded = Self.applyHistoricalGuards(
                validated,
                turn: turn,
                candidates: candidates,
                wallClockNow: Date()
            )
            let applyResult = try await store.applyMemoryOperations(
                guarded.operations,
                for: turn,
                extractorVersion: MemoryExtractorPrompt.version,
                modelName: extractor.modelName,
                now: Date()
            )
            switch applyResult {
            case .alreadyProcessed(let record):
                return .init(
                    result: .alreadyProcessed(status: record.status ?? .failed),
                    skippedExpiredEphemeral: guarded.expired,
                    skippedTemporalConflict: guarded.temporal
                )
            case .applied(let record, let mutationCount):
                let result: MemoryProcessingResult = record.status == .noop
                    ? .noop(metrics: output.metrics)
                    : .processed(operationCount: mutationCount, metrics: output.metrics)
                return .init(
                    result: result,
                    skippedExpiredEphemeral: guarded.expired,
                    skippedTemporalConflict: guarded.temporal
                )
            }
        } catch is CancellationError {
            return .init(result: await recordFailure(turn, error: .networkError), skippedExpiredEphemeral: 0, skippedTemporalConflict: 0)
        } catch let error as MemoryProcessingError {
            return .init(result: await recordFailure(turn, error: error), skippedExpiredEphemeral: 0, skippedTemporalConflict: 0)
        } catch {
            return .init(result: await recordFailure(turn, error: .persistenceError), skippedExpiredEphemeral: 0, skippedTemporalConflict: 0)
        }
    }

    private static func applyHistoricalGuards(
        _ operations: [ValidatedMemoryOperation],
        turn: CompletedTurnSnapshot,
        candidates: [ExistingMemoryCandidate],
        wallClockNow: Date
    ) -> (operations: [ValidatedMemoryOperation], expired: Int, temporal: Int) {
        guard turn.origin == .historicalBackfill else { return (operations, 0, 0) }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var output: [ValidatedMemoryOperation] = []
        var expired = 0
        var temporal = 0

        for operation in operations {
            switch operation {
            case .add(let kind, let text, let importance, let confidence):
                if isExpired(kind: kind, evidenceAt: turn.completedAt, now: wallClockNow) {
                    expired += 1
                    continue
                }
                let newer = candidates.filter { $0.kind == kind && $0.lastConfirmedAt > turn.completedAt }
                if let same = newer.first(where: { equivalent($0.canonicalText, text) }) {
                    output.append(.reinforce(existingMemoryID: same.id, importance: importance, confidence: confidence))
                    continue
                }
                if !newer.isEmpty && [.preference, .ongoingContext, .recentState].contains(kind) {
                    temporal += 1
                    continue
                }
                output.append(operation)

            case .reinforce:
                output.append(operation)

            case .supersede(let id, let kind, _, _, _):
                if isExpired(kind: kind, evidenceAt: turn.completedAt, now: wallClockNow) {
                    expired += 1
                    continue
                }
                if let candidate = byID[id], candidate.lastConfirmedAt > turn.completedAt {
                    temporal += 1
                    continue
                }
                output.append(operation)
            }
        }
        return (output, expired, temporal)
    }

    private static func isExpired(kind: MemoryKind, evidenceAt: Date, now: Date) -> Bool {
        let lifetime: TimeInterval? = switch kind {
        case .recentState: 14 * 86_400
        case .ongoingContext: 90 * 86_400
        default: nil
        }
        return lifetime.map { evidenceAt.addingTimeInterval($0) <= now } ?? false
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        func normalize(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        return normalize(lhs) == normalize(rhs)
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
