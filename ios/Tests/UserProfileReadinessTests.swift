import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

@MainActor
final class UserProfileReadinessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    func testUninitializedFastPathReturnsNilWithoutCreatingProfile() async throws {
        let container = try makeContainer()
        let store = MemoryStore(modelContainer: container)
        let manager = UserProfileManager(store: store)
        let initialState = await manager.readiness()
        let initialProfile = await manager.readyProfileForChat(now: now)
        XCTAssertEqual(initialState, .uninitialized)
        XCTAssertNil(initialProfile)
        let persistedProfile = try await store.profile(scopeID: MemoryScope.localDefault)
        XCTAssertNil(persistedProfile)
    }

    func testInitialReconcileTransitionsToReadyAndFastPathUsesCachedSnapshot() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        _ = try await insertPreference(store, expiresAt: nil)
        let manager = UserProfileManager(store: store)
        _ = try await manager.refreshIfNeeded(now: now)
        let readyState = await manager.readiness()
        XCTAssertEqual(readyState, .ready)
        let ready = await manager.readyProfileForChat(now: now)
        XCTAssertEqual(ready?.payload.preferences.map(\.text), ["用户偏好节奏紧凑的电影。"])
    }

    func testDirtyFastPathImmediatelyReturnsNilAndDoesNotExposeStaleProfile() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        _ = try await insertPreference(store, expiresAt: nil)
        let manager = UserProfileManager(store: store)
        _ = try await manager.refreshIfNeeded(now: now)
        await manager.markDirty()
        let started = ContinuousClock.now
        let profile = await manager.readyProfileForChat(now: now)
        let dirtyState = await manager.readiness()
        XCTAssertNil(profile)
        XCTAssertEqual(dirtyState, .dirty)
        XCTAssertLessThan(milliseconds(started.duration(to: .now)), 100)
    }

    func testTTLDueFastPathReturnsNilAndSchedulesRefreshWithoutWaiting() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        _ = try await insertPreference(store, expiresAt: now.addingTimeInterval(60))
        let manager = UserProfileManager(store: store)
        _ = try await manager.refreshIfNeeded(now: now)
        let started = ContinuousClock.now
        let expiredProfile = await manager.readyProfileForChat(now: now.addingTimeInterval(120))
        XCTAssertNil(expiredProfile)
        XCTAssertLessThan(milliseconds(started.duration(to: .now)), 100)
        let scheduledState = await manager.readiness()
        XCTAssertTrue([.dirty, .refreshing, .ready].contains(scheduledState))
        for _ in 0..<500 {
            if await manager.readiness() == .ready { break }
            await Task.yield()
        }
        let finalState = await manager.readiness()
        let finalProfile = await manager.readyProfileForChat(now: now.addingTimeInterval(120))
        XCTAssertEqual(finalState, .ready)
        XCTAssertNil(finalProfile)
    }

    func testRefreshFailureTransitionsToFailedAndChatFailsOpen() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(UserMemoryProfile(
            scopeID: MemoryScope.localDefault,
            profileData: Data("not valid JSON".utf8)
        ))
        try context.save()
        let manager = UserProfileManager(store: MemoryStore(modelContainer: container))
        do {
            _ = try await manager.refreshIfNeeded(now: now)
            XCTFail("Expected corrupt profile decode failure")
        } catch {
            XCTAssertEqual(error as? MemoryError, .decodingFailure)
        }
        let failedState = await manager.readiness()
        let failedProfile = await manager.readyProfileForChat(now: now)
        XCTAssertEqual(failedState, .failed)
        XCTAssertNil(failedProfile)
    }

    func testRefreshInProgressDoesNotBlockFastPathOrExposeProfile() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for index in 0..<5_000 {
            context.insert(MemoryItem(
                scopeID: MemoryScope.localDefault,
                kindRawValue: MemoryKind.preference.rawValue,
                canonicalText: "合成偏好 \(index)",
                importance: 0.8,
                confidence: 0.9,
                createdAt: now,
                updatedAt: now,
                lastConfirmedAt: now
            ))
        }
        try context.save()
        let manager = UserProfileManager(store: MemoryStore(modelContainer: container))
        let refresh = Task { try await manager.refreshIfNeeded(now: now) }
        for _ in 0..<200 {
            if await manager.readiness() == .refreshing { break }
            await Task.yield()
        }
        let refreshingState = await manager.readiness()
        XCTAssertEqual(refreshingState, .refreshing)
        let started = ContinuousClock.now
        let inFlightProfile = await manager.readyProfileForChat(now: now)
        XCTAssertNil(inFlightProfile)
        XCTAssertLessThan(milliseconds(started.duration(to: .now)), 100)
        _ = try await refresh.value
        let completedState = await manager.readiness()
        XCTAssertEqual(completedState, .ready)
    }

    func testMutationDuringRefreshCannotPublishStaleGeneration() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for index in 0..<2_000 {
            context.insert(MemoryItem(
                scopeID: MemoryScope.localDefault,
                kindRawValue: MemoryKind.preference.rawValue,
                canonicalText: "初始偏好 \(index)",
                createdAt: now, updatedAt: now, lastConfirmedAt: now
            ))
        }
        try context.save()
        let store = MemoryStore(modelContainer: container)
        let manager = UserProfileManager(store: store)
        let refresh = Task { try await manager.refreshIfNeeded(now: now) }
        for _ in 0..<200 {
            if await manager.readiness() == .refreshing { break }
            await Task.yield()
        }
        _ = try await store.insertMemory(
            scopeID: MemoryScope.localDefault,
            draft: .init(
                kind: .ongoingContext, canonicalText: "用户正在进行新项目。",
                createdAt: now, updatedAt: now, lastConfirmedAt: now
            )
        )
        await manager.markDirty()
        _ = try await refresh.value
        let snapshot = try await manager.profileSnapshot(now: now)
        XCTAssertTrue(snapshot.payload.ongoing.contains { $0.text == "用户正在进行新项目。" })
    }

    private func insertPreference(_ store: MemoryStore, expiresAt: Date?) async throws -> MemoryItemSnapshot {
        try await store.insertMemory(
            scopeID: MemoryScope.localDefault,
            draft: .init(
                kind: .preference,
                canonicalText: "用户偏好节奏紧凑的电影。",
                createdAt: now,
                updatedAt: now,
                lastConfirmedAt: now,
                expiresAt: expiresAt
            )
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "ProfileReadiness-\(UUID().uuidString)", schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
    }

    private func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
