import CryptoKit
import Foundation

struct UserProfileConfiguration: Sendable, Equatable {
    var maximumDurable = 8
    var maximumPreferences = 8
    var maximumOngoing = 6
    var maximumRecentState = 6
    var maximumRecentFocus = 5
    var preferenceHalfLifeDays = 730.0
    var ongoingHalfLifeDays = 30.0
    var recentStateHalfLifeDays = 7.0
    var recentFocusWindowDays = 30.0
    var ongoingFocusWindowDays = 90.0
    var reinforcementK = MemoryReinforcementSaturation.defaultK
}

enum UserProfileRefreshResult: Sendable, Equatable {
    case noChange(UserMemoryProfileSnapshot)
    case updated(UserMemoryProfileSnapshot)

    var snapshot: UserMemoryProfileSnapshot {
        switch self {
        case .noChange(let value), .updated(let value): value
        }
    }
}

enum UserProfileReadinessState: String, Sendable, Equatable {
    case uninitialized
    case ready
    case dirty
    case refreshing
    case failed
}

struct UserProfileChatSnapshot: Sendable, Equatable {
    let scopeID: String
    let payload: UserMemoryProfilePayload
}

struct UserProfileSectionScore: Sendable, Equatable {
    let section: String
    let rank: Int
    let memoryID: UUID
    let canonicalText: String
    let finalScore: Double
    let importance: Double
    let confidence: Double
    let reinforcement: Double
    let recency: Double
    let lastConfirmedAt: Date
    let expiresAt: Date?
}

struct UserProfileDerivation: Sendable, Equatable {
    let payload: UserMemoryProfilePayload
    let eligibleCount: Int
    let debugScores: [UserProfileSectionScore]
    let eligibilityMilliseconds: Double
    let rankingMilliseconds: Double
}

actor UserProfileManager {
    private let store: MemoryStore
    private let configuration: UserProfileConfiguration
    private var readinessState: UserProfileReadinessState = .uninitialized
    private var readySnapshot: UserMemoryProfileSnapshot?
    private var refreshTask: Task<UserProfileRefreshResult, Error>?
    private var refreshTaskGeneration: Int?
    private var mutationGeneration = 0
    private var maintenanceHoldCount = 0

    init(store: MemoryStore, configuration: UserProfileConfiguration = .init()) {
        self.store = store
        self.configuration = configuration
    }

    func refreshIfNeeded(
        scopeID: String = MemoryScope.localDefault,
        now: Date = Date()
    ) async throws -> UserProfileRefreshResult {
        let (task, generation) = beginRefreshIfNeeded(scopeID: scopeID, now: now)
        return try await completeRefresh(task: task, generation: generation, scopeID: scopeID, now: now)
    }

    private func beginRefreshIfNeeded(
        scopeID: String,
        now: Date
    ) -> (Task<UserProfileRefreshResult, Error>, Int) {
        if let existing = refreshTask, let existingGeneration = refreshTaskGeneration {
            return (existing, existingGeneration)
        }
        readinessState = .refreshing
        let generation = mutationGeneration
        let store = self.store
        let configuration = self.configuration
        let task = Task {
            try await Self.reconcile(
                store: store,
                configuration: configuration,
                scopeID: scopeID,
                now: now
            )
        }
        refreshTask = task
        refreshTaskGeneration = generation
        return (task, generation)
    }

    private func completeRefresh(
        task: Task<UserProfileRefreshResult, Error>,
        generation: Int,
        scopeID: String,
        now: Date
    ) async throws -> UserProfileRefreshResult {
        do {
            let result = try await task.value
            if refreshTaskGeneration == generation {
                refreshTask = nil
                refreshTaskGeneration = nil
            }
            if generation != mutationGeneration {
                readinessState = .dirty
                readySnapshot = nil
                return try await refreshIfNeeded(scopeID: scopeID, now: now)
            }
            readySnapshot = result.snapshot
            readinessState = .ready
            return result
        } catch {
            if refreshTaskGeneration == generation {
                refreshTask = nil
                refreshTaskGeneration = nil
                readySnapshot = nil
                readinessState = .failed
            }
            throw error
        }
    }

    func rebuild(
        scopeID: String = MemoryScope.localDefault,
        now: Date = Date()
    ) async throws -> UserProfileRefreshResult {
        try await refreshIfNeeded(scopeID: scopeID, now: now)
    }

    /// This is the only supported profile read boundary. It refreshes expired snapshots before
    /// returning and never exposes SwiftData models across actors.
    func profileSnapshot(
        scopeID: String = MemoryScope.localDefault,
        now: Date = Date()
    ) async throws -> UserMemoryProfileSnapshot {
        let result = try await refreshIfNeeded(scopeID: scopeID, now: now)
        return result.snapshot
    }

    /// Chat-only O(1) path. It never reads MemoryStore and never performs a rebuild.
    func readyProfileForChat(
        scopeID: String = MemoryScope.localDefault,
        now: Date = Date()
    ) -> UserProfileChatSnapshot? {
        guard maintenanceHoldCount == 0,
              readinessState == .ready,
              let snapshot = readySnapshot,
              snapshot.scopeID == scopeID
        else { return nil }
        if let nextRefreshAt = snapshot.payload.nextRefreshAt, now >= nextRefreshAt {
            mutationGeneration += 1
            readinessState = .dirty
            readySnapshot = nil
            scheduleRefresh(scopeID: scopeID, now: now)
            return nil
        }
        let payload = snapshot.payload
        guard !payload.durable.isEmpty || !payload.preferences.isEmpty || !payload.ongoing.isEmpty
                || !payload.recentState.isEmpty || !payload.recentFocus.isEmpty
        else { return nil }
        return .init(scopeID: scopeID, payload: payload)
    }

    func readiness() -> UserProfileReadinessState { readinessState }

    func markDirty(scopeID: String = MemoryScope.localDefault) {
        mutationGeneration += 1
        readinessState = .dirty
        readySnapshot = nil
    }

    func markDirtyAndScheduleRefresh(
        scopeID: String = MemoryScope.localDefault,
        now: Date = Date()
    ) {
        markDirty(scopeID: scopeID)
        if maintenanceHoldCount == 0 {
            scheduleRefresh(scopeID: scopeID, now: now)
        }
    }

    func beginMaintenanceHold(scopeID: String = MemoryScope.localDefault) {
        maintenanceHoldCount += 1
        markDirty(scopeID: scopeID)
    }

    func endMaintenanceHold(
        scopeID: String = MemoryScope.localDefault,
        now: Date = Date()
    ) {
        guard maintenanceHoldCount > 0 else { return }
        maintenanceHoldCount -= 1
        if maintenanceHoldCount == 0 {
            markDirty(scopeID: scopeID)
            scheduleRefresh(scopeID: scopeID, now: now)
        }
    }

    func isMaintenanceHeld() -> Bool { maintenanceHoldCount > 0 }

    func derivationSnapshot(
        scopeID: String = MemoryScope.localDefault,
        now: Date = Date()
    ) async throws -> UserProfileDerivation {
        let memories = try await store.listMemories(scopeID: scopeID)
        return Self.derive(memories: memories, scopeID: scopeID, now: now, configuration: configuration)
    }

    nonisolated static func derive(
        memories: [MemoryItemSnapshot],
        scopeID: String,
        now: Date,
        configuration: UserProfileConfiguration = .init()
    ) -> UserProfileDerivation {
        let eligibilityStartedAt = Date()
        let eligible = memories.filter { item in
            item.scopeID == scopeID
                && item.status == .active
                && item.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && (item.expiresAt == nil || item.expiresAt! > now)
                && MemoryEvidenceFilter.allowsProfileText(item.canonicalText)
        }
        let eligibilityMilliseconds = Date().timeIntervalSince(eligibilityStartedAt) * 1_000

        let digest = sourceDigest(eligible)
        let nextRefreshAt = eligible.compactMap(\.expiresAt).min()
        let rankingStartedAt = Date()
        let durable = ranked(
            eligible.filter { $0.kind == .durableFact }, section: "durable",
            limit: configuration.maximumDurable, now: now, configuration: configuration
        ) { item in
            0.45 * MemoryScore.clamped(item.importance)
                + 0.35 * MemoryScore.clamped(item.confidence)
                + 0.20 * reinforcement(item, configuration)
        }
        let preferences = ranked(
            eligible.filter { $0.kind == .preference }, section: "preferences",
            limit: configuration.maximumPreferences, now: now, configuration: configuration
        ) { item in
            0.40 * MemoryScore.clamped(item.importance)
                + 0.30 * MemoryScore.clamped(item.confidence)
                + 0.20 * reinforcement(item, configuration)
                + 0.10 * recency(item, now: now, halfLifeDays: configuration.preferenceHalfLifeDays)
        }
        let ongoing = ranked(
            eligible.filter { $0.kind == .ongoingContext }, section: "ongoing",
            limit: configuration.maximumOngoing, now: now, configuration: configuration
        ) { item in
            0.30 * MemoryScore.clamped(item.importance)
                + 0.25 * MemoryScore.clamped(item.confidence)
                + 0.30 * recency(item, now: now, halfLifeDays: configuration.ongoingHalfLifeDays)
                + 0.15 * reinforcement(item, configuration)
        }
        let recentState = ranked(
            eligible.filter { $0.kind == .recentState }, section: "recentState",
            limit: configuration.maximumRecentState, now: now, configuration: configuration
        ) { item in
            0.55 * recency(item, now: now, halfLifeDays: configuration.recentStateHalfLifeDays)
                + 0.25 * MemoryScore.clamped(item.importance)
                + 0.20 * MemoryScore.clamped(item.confidence)
        }

        let focusCandidates = eligible.filter { item in
            let age = ageDays(item, now: now)
            return switch item.kind {
            case .ongoingContext: age <= configuration.ongoingFocusWindowDays
            case .recentState, .event, .preference, .durableFact: age <= configuration.recentFocusWindowDays
            case .other: false
            }
        }
        let recentFocus = ranked(
            focusCandidates, section: "recentFocus", limit: configuration.maximumRecentFocus,
            now: now, configuration: configuration
        ) { item in
            let window = item.kind == .ongoingContext
                ? configuration.ongoingFocusWindowDays
                : configuration.recentFocusWindowDays
            let focusRecency = max(0, 1 - ageDays(item, now: now) / max(1, window))
            let boundedValue = 0.45 * MemoryScore.clamped(item.importance)
                + 0.35 * MemoryScore.clamped(item.confidence)
                + 0.20 * reinforcement(item, configuration)
            return focusRecency * boundedValue
        }

        let payload = UserMemoryProfilePayload(
            generatedAt: now,
            sourceDigest: digest,
            nextRefreshAt: nextRefreshAt,
            durable: durable.entries,
            preferences: preferences.entries,
            ongoing: ongoing.entries,
            recentState: recentState.entries,
            recentFocus: recentFocus.entries
        )
        return .init(
            payload: payload,
            eligibleCount: eligible.count,
            debugScores: durable.scores + preferences.scores + ongoing.scores + recentState.scores + recentFocus.scores,
            eligibilityMilliseconds: eligibilityMilliseconds,
            rankingMilliseconds: Date().timeIntervalSince(rankingStartedAt) * 1_000
        )
    }

    private func scheduleRefresh(scopeID: String, now: Date) {
        let (task, generation) = beginRefreshIfNeeded(scopeID: scopeID, now: now)
        Task(priority: .utility) { [weak self] in
            _ = try? await self?.completeRefresh(
                task: task,
                generation: generation,
                scopeID: scopeID,
                now: now
            )
        }
    }

    private nonisolated static func reconcile(
        store: MemoryStore,
        configuration: UserProfileConfiguration,
        scopeID: String,
        now: Date
    ) async throws -> UserProfileRefreshResult {
        // Retry conflicts because another manager/process may commit during snapshot fetches.
        for attempt in 0..<3 {
            let current = try await store.getOrCreateProfile(scopeID: scopeID)
            let memories = try await store.listMemories(scopeID: scopeID)
            let candidate = derive(
                memories: memories,
                scopeID: scopeID,
                now: now,
                configuration: configuration
            )
            if current.payload.schemaVersion == UserMemoryProfilePayload.currentSchemaVersion,
               current.payload.sourceDigest == candidate.payload.sourceDigest {
                return .noChange(current)
            }
            do {
                let updated = try await store.updateProfile(
                    scopeID: scopeID,
                    expectedRevision: current.revision,
                    payload: candidate.payload
                )
                return .updated(updated)
            } catch let error as MemoryError {
                if case .revisionConflict = error, attempt < 2 { continue }
                throw error
            }
        }
        let latest = try await store.getOrCreateProfile(scopeID: scopeID)
        throw MemoryError.revisionConflict(expected: latest.revision, actual: latest.revision)
    }

    private nonisolated static func ranked(
        _ items: [MemoryItemSnapshot],
        section: String,
        limit: Int,
        now: Date,
        configuration: UserProfileConfiguration,
        score: (MemoryItemSnapshot) -> Double
    ) -> (entries: [ProfileEntry], scores: [UserProfileSectionScore]) {
        let ordered = items.map { ($0, MemoryScore.clamped(score($0))) }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.id.uuidString.lowercased() < $1.0.id.uuidString.lowercased()
        }.prefix(max(0, limit))
        let entries = ordered.map { item, _ in
            ProfileEntry(
                text: item.canonicalText,
                sourceMemoryIDs: [item.id],
                lastConfirmedAt: item.lastConfirmedAt
            )
        }
        let scores = ordered.enumerated().map { offset, value in
            let item = value.0
            return UserProfileSectionScore(
                section: section,
                rank: offset + 1,
                memoryID: item.id,
                canonicalText: item.canonicalText,
                finalScore: value.1,
                importance: MemoryScore.clamped(item.importance),
                confidence: MemoryScore.clamped(item.confidence),
                reinforcement: reinforcement(item, configuration),
                recency: recency(item, now: now, halfLifeDays: 30),
                lastConfirmedAt: item.lastConfirmedAt,
                expiresAt: item.expiresAt
            )
        }
        return (entries, scores)
    }

    private nonisolated static func reinforcement(
        _ item: MemoryItemSnapshot,
        _ configuration: UserProfileConfiguration
    ) -> Double {
        MemoryReinforcementSaturation.score(count: item.reinforcementCount, k: configuration.reinforcementK)
    }

    private nonisolated static func ageDays(_ item: MemoryItemSnapshot, now: Date) -> Double {
        max(0, now.timeIntervalSince(item.lastConfirmedAt) / 86_400)
    }

    private nonisolated static func recency(
        _ item: MemoryItemSnapshot,
        now: Date,
        halfLifeDays: Double
    ) -> Double {
        exp(-log(2) * ageDays(item, now: now) / max(1, halfLifeDays))
    }

    private struct DigestRecord: Codable {
        let id: String
        let kind: String
        let canonicalText: String
        let status: String
        let importanceBits: UInt64
        let confidenceBits: UInt64
        let lastConfirmedMilliseconds: Int64
        let expiresMilliseconds: Int64?
        let reinforcementCount: Int
    }

    private nonisolated static func sourceDigest(_ memories: [MemoryItemSnapshot]) -> String {
        let records = memories.sorted {
            $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }.map { item in
            DigestRecord(
                id: item.id.uuidString.lowercased(),
                kind: item.kindRawValue,
                canonicalText: item.canonicalText,
                status: item.statusRawValue,
                importanceBits: item.importance.bitPattern,
                confidenceBits: item.confidence.bitPattern,
                lastConfirmedMilliseconds: Int64((item.lastConfirmedAt.timeIntervalSince1970 * 1_000).rounded()),
                expiresMilliseconds: item.expiresAt.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) },
                reinforcementCount: item.reinforcementCount
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(records)) ?? Data("digest-encoding-failure".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
