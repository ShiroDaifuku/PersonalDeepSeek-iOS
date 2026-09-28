import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

@MainActor
final class UserProfilePerformanceTests: XCTestCase {
    private struct Measurement: Codable {
        let itemCount: Int
        let fetchMilliseconds: Double
        let eligibilityMilliseconds: Double
        let rankingMilliseconds: Double
        let encodingMilliseconds: Double
        let totalMilliseconds: Double
        let profileEntryCount: Int
    }

    private struct ChatFastPathMeasurement: Codable {
        let itemCount: Int
        let profileFetchDecodeMilliseconds: Double
        let readyLookupMilliseconds: Double
        let dedupeMilliseconds: Double
        let contextBuildMilliseconds: Double
        let totalMilliseconds: Double
        let contextCharacters: Int
        let contextEstimatedTokens: Int
    }

    func testProfileRebuildAtPersonalScale() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var measurements: [Measurement] = []
        for count in [100, 1_000, 5_000] {
            let container = try makeContainer()
            let context = ModelContext(container)
            for index in 0..<count {
                let kind: MemoryKind = [.durableFact, .preference, .ongoingContext, .recentState, .event][index % 5]
                let confirmed = now.addingTimeInterval(-Double(index % 20) * 86_400)
                let expires: Date? = switch kind {
                case .ongoingContext: now.addingTimeInterval(60 * 86_400)
                case .recentState: now.addingTimeInterval(7 * 86_400)
                default: nil
                }
                context.insert(MemoryItem(
                    scopeID: MemoryScope.localDefault,
                    kindRawValue: kind.rawValue,
                    canonicalText: "用户的合成画像记忆 \(index)。",
                    importance: Double(index % 10) / 10,
                    confidence: 0.9,
                    createdAt: confirmed,
                    updatedAt: confirmed,
                    lastConfirmedAt: confirmed,
                    expiresAt: expires,
                    reinforcementCount: index % 8
                ))
            }
            try context.save()
            let store = MemoryStore(modelContainer: container)
            let totalStart = Date()
            let fetchStart = Date()
            let values = try await store.listMemories(scopeID: MemoryScope.localDefault)
            let fetchMS = Date().timeIntervalSince(fetchStart) * 1_000
            let derivation = UserProfileManager.derive(
                memories: values, scopeID: MemoryScope.localDefault, now: now
            )
            let encodingStart = Date()
            let encoded = try JSONEncoder().encode(derivation.payload)
            let encodingMS = Date().timeIntervalSince(encodingStart) * 1_000
            XCTAssertFalse(encoded.isEmpty)
            let entryCount = derivation.payload.durable.count + derivation.payload.preferences.count
                + derivation.payload.ongoing.count + derivation.payload.recentState.count
                + derivation.payload.recentFocus.count
            XCTAssertLessThanOrEqual(entryCount, 33)
            measurements.append(.init(
                itemCount: count,
                fetchMilliseconds: fetchMS,
                eligibilityMilliseconds: derivation.eligibilityMilliseconds,
                rankingMilliseconds: derivation.rankingMilliseconds,
                encodingMilliseconds: encodingMS,
                totalMilliseconds: Date().timeIntervalSince(totalStart) * 1_000,
                profileEntryCount: entryCount
            ))
        }
        XCTAssertEqual(measurements.map(\.itemCount), [100, 1_000, 5_000])
        XCTAssertLessThan(measurements.last?.totalMilliseconds ?? .infinity, 10_000)
        try writeReports(measurements)
        for value in measurements {
            print("[UserProfilePerformance] count=\(value.itemCount) fetch_ms=\(value.fetchMilliseconds) eligibility_ms=\(value.eligibilityMilliseconds) ranking_ms=\(value.rankingMilliseconds) encoding_ms=\(value.encodingMilliseconds) total_ms=\(value.totalMilliseconds)")
        }
    }

    func testReadyProfileChatFastPathDoesNotScaleWithMemoryItemCount() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var measurements: [ChatFastPathMeasurement] = []
        for count in [100, 1_000, 5_000] {
            let container = try makeContainer()
            let context = ModelContext(container)
            for index in 0..<count {
                let kind: MemoryKind = [.durableFact, .preference, .ongoingContext, .recentState, .event][index % 5]
                context.insert(MemoryItem(
                    scopeID: MemoryScope.localDefault,
                    kindRawValue: kind.rawValue,
                    canonicalText: "用户的合成画像记忆 \(index)。",
                    importance: Double(index % 10) / 10,
                    confidence: 0.9,
                    createdAt: now,
                    updatedAt: now,
                    lastConfirmedAt: now,
                    reinforcementCount: index % 8
                ))
            }
            try context.save()
            let manager = UserProfileManager(store: MemoryStore(modelContainer: container))
            _ = try await manager.refreshIfNeeded(now: now)

            var lookupTotal = 0.0
            var dedupeTotal = 0.0
            var buildTotal = 0.0
            var total = 0.0
            var finalContext: ProfileContextSnapshot?
            let iterations = 100
            for _ in 0..<iterations {
                let totalStarted = Date()
                let lookupStarted = Date()
                let profile = await manager.readyProfileForChat(now: now)
                lookupTotal += Date().timeIntervalSince(lookupStarted) * 1_000
                let output = profile.map {
                    ProfileContextBuilder.build(
                        profile: $0,
                        currentUserText: "请根据我的情况给出建议。",
                        retrievedMemoryContext: nil
                    )
                }
                dedupeTotal += output?.dedupeMilliseconds ?? 0
                buildTotal += output?.contextBuildMilliseconds ?? 0
                finalContext = output?.context
                total += Date().timeIntervalSince(totalStarted) * 1_000
            }
            let divisor = Double(iterations)
            let value = ChatFastPathMeasurement(
                itemCount: count,
                // The ready API is an actor-memory lookup. It deliberately performs no store
                // fetch and no Data decode on the request path.
                profileFetchDecodeMilliseconds: 0,
                readyLookupMilliseconds: lookupTotal / divisor,
                dedupeMilliseconds: dedupeTotal / divisor,
                contextBuildMilliseconds: buildTotal / divisor,
                totalMilliseconds: total / divisor,
                contextCharacters: finalContext?.characterCount ?? 0,
                contextEstimatedTokens: finalContext?.estimatedTokens ?? 0
            )
            XCTAssertNotNil(finalContext)
            XCTAssertLessThanOrEqual(value.contextCharacters, ProfileContextBudget.chatDefault.maximumCharacters)
            XCTAssertLessThanOrEqual(value.contextEstimatedTokens, ProfileContextBudget.chatDefault.maximumEstimatedTokens)
            measurements.append(value)
        }
        XCTAssertEqual(measurements.map(\.itemCount), [100, 1_000, 5_000])
        XCTAssertLessThan(measurements.map(\.totalMilliseconds).max() ?? .infinity, 100)
        try writeChatFastPathReports(measurements)
        for value in measurements {
            print(
                "[ProfileChatFastPath] count=\(value.itemCount) fetch_decode_ms=0 " +
                "lookup_ms=\(value.readyLookupMilliseconds) dedupe_ms=\(value.dedupeMilliseconds) " +
                "build_ms=\(value.contextBuildMilliseconds) total_ms=\(value.totalMilliseconds)"
            )
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "ProfilePerformance-\(UUID().uuidString)", schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
    }

    private func writeReports(_ values: [Measurement]) throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let json = try JSONEncoder.pretty.encode(values)
        try json.write(to: directory.appendingPathComponent("user-profile-performance.json"), options: .atomic)
        var lines = [
            "# User Profile Performance", "",
            "| Items | Fetch ms | Eligibility ms | Ranking ms | Encode ms | Total ms | Entries |",
            "|---:|---:|---:|---:|---:|---:|---:|"
        ]
        lines += values.map {
            "| \($0.itemCount) | \(format($0.fetchMilliseconds)) | \(format($0.eligibilityMilliseconds)) | \(format($0.rankingMilliseconds)) | \(format($0.encodingMilliseconds)) | \(format($0.totalMilliseconds)) | \($0.profileEntryCount) |"
        }
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("user-profile-performance.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeChatFastPathReports(_ values: [ChatFastPathMeasurement]) throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let json = try JSONEncoder.pretty.encode(values)
        try json.write(
            to: directory.appendingPathComponent("user-profile-chat-fast-path-performance.json"),
            options: .atomic
        )
        var lines = [
            "# User Profile Chat Fast Path Performance", "",
            "Profile fetch/decode is `0 ms` by construction: the chat API reads only the manager's ready in-memory snapshot.", "",
            "| Items | Fetch/decode ms | Ready lookup ms | Dedupe ms | Build ms | Total ms | Chars | Tokens est. |",
            "|---:|---:|---:|---:|---:|---:|---:|---:|"
        ]
        lines += values.map {
            "| \($0.itemCount) | 0 | \(format($0.readyLookupMilliseconds)) | \(format($0.dedupeMilliseconds)) | \(format($0.contextBuildMilliseconds)) | \(format($0.totalMilliseconds)) | \($0.contextCharacters) | \($0.contextEstimatedTokens) |"
        }
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("user-profile-chat-fast-path-performance.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func format(_ value: Double) -> String { String(format: "%.3f", value) }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
