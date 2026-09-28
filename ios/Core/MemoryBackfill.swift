import Foundation
import SwiftData

struct MemoryBackfillPerformance: Sendable, Equatable {
    let fetchMilliseconds: Double
    let pairingMilliseconds: Double
    let turnRecordMilliseconds: Double
    let sortMilliseconds: Double
    let totalMilliseconds: Double
}

struct MemoryBackfillPreflight: Sendable, Equatable {
    let conversationCount: Int
    let eligibleTurnCount: Int
    let alreadyProcessedCount: Int
    let failedRetryCount: Int
    let estimatedRequestCount: Int
    let skippedMalformedCount: Int
    let danglingTurnCount: Int
    let earliestTurnDate: Date?
    let latestTurnDate: Date?
    let estimatedInputTokens: Int
    let performance: MemoryBackfillPerformance
}

enum MemoryBackfillRunState: String, Sendable, Equatable {
    case idle
    case running
    case completed
    case cancelled
    case partiallyFailed
}

struct MemoryBackfillProgress: Sendable, Equatable {
    var state: MemoryBackfillRunState = .idle
    var eligible = 0
    var processed = 0
    var succeeded = 0
    var noop = 0
    var skippedAlreadyProcessed = 0
    var skippedExpiredEphemeral = 0
    var skippedTemporalConflict = 0
    var failed = 0
    var remaining = 0
    var requests = 0
    var promptTokens = 0
    var completionTokens = 0
    var totalTokens = 0
    var missingUsage = 0

    var averageTokensPerRequest: Double {
        requests == 0 ? 0 : Double(totalTokens) / Double(requests)
    }
}

struct HistoricalTurnScan: Sendable {
    let conversationCount: Int
    let turns: [HistoricalCompletedTurnSnapshot]
    let skippedMalformed: Int
    let dangling: Int
    let estimatedInputTokens: Int
    let fetchMilliseconds: Double
    let pairingMilliseconds: Double
    let sortMilliseconds: Double
}

@ModelActor
actor HistoricalTurnScanner {
    func scan() throws -> HistoricalTurnScan {
        let fetchStarted = ContinuousClock.now
        let conversations: [Conversation]
        do {
            conversations = try modelContext.fetch(FetchDescriptor<Conversation>())
        } catch {
            throw MemoryError.persistenceFailure(error.localizedDescription)
        }
        let fetchMilliseconds = Self.milliseconds(fetchStarted.duration(to: .now))
        let pairingStarted = ContinuousClock.now
        var turns: [HistoricalCompletedTurnSnapshot] = []
        var malformed = 0
        var dangling = 0
        var inputCharacters = 0

        for conversation in conversations {
            let ordered = conversation.messages.sorted {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
                    : $0.createdAt < $1.createdAt
            }
            var pendingUser: ChatMessage?
            var assistants: [ChatMessage] = []

            func finishSegment() {
                guard let user = pendingUser else { return }
                let userText = user.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let validAssistants = assistants.filter {
                    !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard !userText.isEmpty else {
                    malformed += 1
                    pendingUser = nil
                    assistants.removeAll(keepingCapacity: true)
                    return
                }
                guard validAssistants.count == 1, assistants.count == 1 else {
                    if assistants.isEmpty || validAssistants.isEmpty { dangling += 1 }
                    else { malformed += 1 }
                    pendingUser = nil
                    assistants.removeAll(keepingCapacity: true)
                    return
                }
                let assistant = validAssistants[0]
                let assistantText = assistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                turns.append(.init(
                    conversationID: conversation.id,
                    userMessageID: user.id,
                    userText: userText,
                    assistantMessageID: assistant.id,
                    assistantText: assistantText,
                    completedAt: assistant.createdAt
                ))
                inputCharacters += userText.count + assistantText.count
                pendingUser = nil
                assistants.removeAll(keepingCapacity: true)
            }

            for message in ordered {
                switch message.role {
                case "user":
                    finishSegment()
                    pendingUser = message
                case "assistant":
                    if pendingUser != nil { assistants.append(message) }
                default:
                    if pendingUser != nil { malformed += 1 }
                    pendingUser = nil
                    assistants.removeAll(keepingCapacity: true)
                }
            }
            finishSegment()
        }
        let pairingMilliseconds = Self.milliseconds(pairingStarted.duration(to: .now))
        let sortStarted = ContinuousClock.now
        turns.sort { lhs, rhs in
            if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
            let left = [lhs.conversationID, lhs.userMessageID, lhs.assistantMessageID].map { $0.uuidString.lowercased() }
            let right = [rhs.conversationID, rhs.userMessageID, rhs.assistantMessageID].map { $0.uuidString.lowercased() }
            return left.lexicographicallyPrecedes(right)
        }
        let sortMilliseconds = Self.milliseconds(sortStarted.duration(to: .now))
        return .init(
            conversationCount: conversations.count,
            turns: turns,
            skippedMalformed: malformed,
            dangling: dangling,
            estimatedInputTokens: Int(ceil(Double(inputCharacters) / 4.0)),
            fetchMilliseconds: fetchMilliseconds,
            pairingMilliseconds: pairingMilliseconds,
            sortMilliseconds: sortMilliseconds
        )
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

actor MemoryBackfillCoordinator {
    private let scanner: HistoricalTurnScanner
    private let store: MemoryStore
    private let processor: MemoryProcessor
    private let profileManager: UserProfileManager
    private var cancelRequested = false
    private var running = false
    private var currentProgress = MemoryBackfillProgress()

    init(
        scanner: HistoricalTurnScanner,
        store: MemoryStore,
        processor: MemoryProcessor,
        profileManager: UserProfileManager
    ) {
        self.scanner = scanner
        self.store = store
        self.processor = processor
        self.profileManager = profileManager
    }

    func preflight(scopeID: String = MemoryScope.localDefault) async throws -> MemoryBackfillPreflight {
        let totalStarted = ContinuousClock.now
        let scan = try await scanner.scan()
        let recordsStarted = ContinuousClock.now
        let records = try await store.listTurnRecords(scopeID: scopeID)
        let recordsMilliseconds = Self.milliseconds(recordsStarted.duration(to: .now))
        let byFingerprint = Dictionary(uniqueKeysWithValues: records.map { ($0.turnFingerprint, $0) })
        let already = scan.turns.reduce(into: 0) { count, turn in
            if byFingerprint[turn.turnFingerprint]?.status?.isProcessed == true { count += 1 }
        }
        let failed = scan.turns.reduce(into: 0) { count, turn in
            if byFingerprint[turn.turnFingerprint]?.status == .failed { count += 1 }
        }
        return .init(
            conversationCount: scan.conversationCount,
            eligibleTurnCount: scan.turns.count,
            alreadyProcessedCount: already,
            failedRetryCount: failed,
            estimatedRequestCount: max(0, scan.turns.count - already),
            skippedMalformedCount: scan.skippedMalformed,
            danglingTurnCount: scan.dangling,
            earliestTurnDate: scan.turns.first?.completedAt,
            latestTurnDate: scan.turns.last?.completedAt,
            estimatedInputTokens: scan.estimatedInputTokens,
            performance: .init(
                fetchMilliseconds: scan.fetchMilliseconds,
                pairingMilliseconds: scan.pairingMilliseconds,
                turnRecordMilliseconds: recordsMilliseconds,
                sortMilliseconds: scan.sortMilliseconds,
                totalMilliseconds: Self.milliseconds(totalStarted.duration(to: .now))
            )
        )
    }

    func progress() -> MemoryBackfillProgress { currentProgress }

    func cancel() { cancelRequested = true }

    func start(
        scopeID: String = MemoryScope.localDefault,
        onProgress: (@Sendable (MemoryBackfillProgress) -> Void)? = nil
    ) async -> MemoryBackfillProgress {
        guard !running else { return currentProgress }
        running = true
        cancelRequested = false
        let scan: HistoricalTurnScan
        do {
            scan = try await scanner.scan()
        } catch {
            running = false
            currentProgress.state = .partiallyFailed
            currentProgress.failed += 1
            onProgress?(currentProgress)
            return currentProgress
        }
        let records = (try? await store.listTurnRecords(scopeID: scopeID)) ?? []
        let processedKeys = Set(records.filter { $0.status?.isProcessed == true }.map(\.turnFingerprint))
        currentProgress = .init(
            state: .running,
            eligible: scan.turns.count,
            processed: 0,
            succeeded: 0,
            noop: 0,
            skippedAlreadyProcessed: processedKeys.intersection(scan.turns.map(\.turnFingerprint)).count,
            skippedExpiredEphemeral: 0,
            skippedTemporalConflict: 0,
            failed: 0,
            remaining: max(0, scan.turns.count - processedKeys.count),
            requests: 0,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
            missingUsage: 0
        )
        onProgress?(currentProgress)
        await profileManager.beginMaintenanceHold(scopeID: scopeID)

        for historical in scan.turns where !processedKeys.contains(historical.turnFingerprint) {
            if cancelRequested || Task.isCancelled { break }
            let details = await processor.processCompletedTurnDetailed(historical.completedTurn(scopeID: scopeID))
            currentProgress.requests += 1
            currentProgress.processed += 1
            currentProgress.remaining = max(0, currentProgress.remaining - 1)
            currentProgress.skippedExpiredEphemeral += details.skippedExpiredEphemeral
            currentProgress.skippedTemporalConflict += details.skippedTemporalConflict
            switch details.result {
            case .processed(_, let metrics):
                currentProgress.succeeded += 1
                addUsage(metrics)
            case .noop(let metrics):
                currentProgress.noop += 1
                addUsage(metrics)
            case .alreadyProcessed:
                currentProgress.skippedAlreadyProcessed += 1
                currentProgress.requests -= 1
            case .failed:
                currentProgress.failed += 1
            }
            onProgress?(currentProgress)
            await Task.yield()
        }

        if cancelRequested || Task.isCancelled {
            currentProgress.state = .cancelled
        } else if currentProgress.failed > 0 {
            currentProgress.state = .partiallyFailed
        } else {
            currentProgress.state = .completed
        }
        running = false
        await profileManager.endMaintenanceHold(scopeID: scopeID)
        onProgress?(currentProgress)
        return currentProgress
    }

    private func addUsage(_ metrics: MemoryExtractionMetrics) {
        guard let prompt = metrics.promptTokens,
              let completion = metrics.completionTokens,
              let total = metrics.totalTokens
        else {
            currentProgress.missingUsage += 1
            return
        }
        currentProgress.promptTokens += prompt
        currentProgress.completionTokens += completion
        currentProgress.totalTokens += total
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
