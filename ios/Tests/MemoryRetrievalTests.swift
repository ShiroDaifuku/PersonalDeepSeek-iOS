import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

@MainActor
final class MemoryRetrievalTests: XCTestCase {
    func testHardEligibilityAndNoResultDoNotLeakMemories() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        _ = try await insert(store, text: "用户喜欢深色模式", status: .active, now: now)
        _ = try await insert(store, text: "用户喜欢法国旅行", status: .superseded, now: now)
        _ = try await insert(store, text: "用户关注北京天气", status: .invalidated, now: now)
        _ = try await insert(store, text: "用户正在学习二次方程", status: .active, expiresAt: now.addingTimeInterval(-1), now: now)
        _ = try await store.insertMemory(scopeID: "other-scope", draft: .init(
            kind: .preference, canonicalText: "用户喜欢巴黎", createdAt: now, updatedAt: now, lastConfirmedAt: now
        ))
        let retriever = MemoryRetriever(store: store, semanticResolver: nil)

        let france = try await retriever.search(.init(primaryText: "法国首都是什么？"), now: now)
        let weather = try await retriever.search(.init(primaryText: "北京天气怎么样？"), now: now)
        let equation = try await retriever.search(.init(primaryText: "二次方程怎么算？"), now: now)
        XCTAssertTrue(france.isEmpty)
        XCTAssertTrue(weather.isEmpty)
        XCTAssertTrue(equation.isEmpty)
        let dark = try await retriever.search(.init(primaryText: "我偏好什么界面模式？"), now: now)
        XCTAssertEqual(dark.map(\.canonicalText), ["用户喜欢深色模式"])
    }

    func testTimeAndImportanceCannotReviveWeakSemanticCandidate() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        let descriptor = TestSemanticResolver.descriptor
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let recentWeak = try await insert(
            store, text: "弱相关的近期项目", importance: 1,
            embedding: try envelope([0, 1], descriptor: descriptor, text: "弱相关的近期项目"),
            now: now.addingTimeInterval(-86_400)
        )
        let oldRelevant = try await insert(
            store, text: "高度相关的长期偏好", importance: 0.5,
            embedding: try envelope([1, 0], descriptor: descriptor, text: "高度相关的长期偏好"),
            now: now.addingTimeInterval(-90 * 86_400)
        )
        let retriever = MemoryRetriever(store: store, semanticResolver: TestSemanticResolver())
        let result = try await retriever.search(.init(primaryText: "语义查询"), now: now)
        XCTAssertEqual(result.first?.memoryID, oldRelevant.id)
        XCTAssertFalse(result.contains { $0.memoryID == recentWeak.id })
    }

    func testOldPreferenceAndDurableFactRemainRetrievable() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let preference = try await insert(
            store, kind: .preference, text: "用户偏好深色模式界面",
            now: now.addingTimeInterval(-180 * 86_400)
        )
        let durable = try await insert(
            store, kind: .durableFact, text: "用户的宠物是一只橘猫",
            now: now.addingTimeInterval(-365 * 86_400)
        )
        let retriever = MemoryRetriever(store: store, semanticResolver: nil)
        let preferenceResult = try await retriever.search(.init(primaryText: "我的界面主题偏好是深色模式吗？"), now: now)
        let durableResult = try await retriever.search(.init(primaryText: "我的宠物猫是什么？"), now: now)
        XCTAssertEqual(preferenceResult.first?.memoryID, preference.id)
        XCTAssertEqual(durableResult.first?.memoryID, durable.id)
    }

    func testContextTextResolvesFollowUpAndConversationExclusionUsesAllSources() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let onlyCurrent = try await insert(store, text: "用户喜欢科幻电影", now: now)
        let shared = try await insert(store, text: "用户喜欢悬疑电影", now: now)
        let current = UUID()
        let other = UUID()
        for (memory, conversation, marker) in [(onlyCurrent, current, "a"), (shared, current, "b"), (shared, other, "c")] {
            _ = try await store.addSource(memoryItemID: memory.id, scopeID: MemoryScope.localDefault, draft: .init(
                sourceConversationID: conversation, turnFingerprint: marker
            ))
        }
        let retriever = MemoryRetriever(store: store, semanticResolver: nil)
        let result = try await retriever.search(.init(
            primaryText: "再推荐一部",
            contextText: "请根据我喜欢的悬疑电影推荐",
            excludingConversationID: current
        ), now: now)
        XCTAssertEqual(result.map(\.memoryID), [shared.id])
        XCTAssertFalse(result.contains { $0.memoryID == onlyCurrent.id })
    }

    func testBackfillWritesOnlyEligibleMissingOrStaleAndIsIdempotent() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let missing = try await insert(store, text: "missing semantic", now: now)
        let current = try await insert(
            store, text: "current semantic",
            embedding: try envelope([1, 0], descriptor: TestSemanticResolver.descriptor, text: "current semantic"), now: now
        )
        let staleDescriptor = MemoryEmbeddingDescriptor(
            provider: "test-semantic", modelIdentifier: "old", revision: 1, dimension: 2,
            modelFamily: "test", language: "zh-Hans", semantic: true
        )
        let stale = try await insert(
            store, text: "stale semantic",
            embedding: try envelope([1, 0], descriptor: staleDescriptor, text: "stale semantic"), now: now
        )
        let expired = try await insert(store, text: "expired semantic", expiresAt: now.addingTimeInterval(-1), now: now)
        let invalidated = try await insert(store, text: "invalid semantic", status: .invalidated, now: now)
        let service = MemoryEmbeddingBackfillService(store: store, resolver: TestSemanticResolver())

        let first = await service.backfill(now: now)
        XCTAssertEqual(first.examined, 3)
        XCTAssertEqual(first.written, 2)
        XCTAssertEqual(first.skippedCurrent, 1)
        XCTAssertEqual(first.failed, 0)
        let second = await service.backfill(now: now)
        XCTAssertEqual(second.written, 0)
        XCTAssertEqual(second.skippedCurrent, 3)
        let savedMissing = try await store.memory(id: missing.id, scopeID: MemoryScope.localDefault)
        let savedStale = try await store.memory(id: stale.id, scopeID: MemoryScope.localDefault)
        let savedCurrent = try await store.memory(id: current.id, scopeID: MemoryScope.localDefault)
        let savedExpired = try await store.memory(id: expired.id, scopeID: MemoryScope.localDefault)
        let savedInvalidated = try await store.memory(id: invalidated.id, scopeID: MemoryScope.localDefault)
        XCTAssertNotNil(savedMissing?.embeddingData)
        XCTAssertNotNil(savedStale?.embeddingData)
        XCTAssertEqual(savedCurrent?.lastConfirmedAt, now)
        XCTAssertNil(savedExpired?.embeddingData)
        XCTAssertNil(savedInvalidated?.embeddingData)
    }

    func testCompletedTurnTimeBecomesLastConfirmedEvidenceTime() async throws {
        let store = MemoryStore(modelContainer: try makeContainer())
        let completed = Date(timeIntervalSince1970: 1_800_000_000)
        let turn = CompletedTurnSnapshot(
            conversationID: UUID(), userMessageID: UUID(), userText: "我喜欢表格",
            assistantMessageID: UUID(), assistantText: "收到", completedAt: completed
        )
        _ = try await store.applyMemoryOperations([
            .add(kind: .preference, canonicalText: "用户喜欢表格。", importance: 0.7, confidence: 0.9)
        ], for: turn, extractorVersion: 1, modelName: "test", now: completed.addingTimeInterval(3_600))
        let addedValues = try await store.listMemories(scopeID: MemoryScope.localDefault)
        let added = try XCTUnwrap(addedValues.first)
        XCTAssertEqual(added.lastConfirmedAt, completed)

        let reinforcedAt = completed.addingTimeInterval(86_400)
        let reinforcement = CompletedTurnSnapshot(
            conversationID: UUID(), userMessageID: UUID(), userText: "我仍然喜欢表格",
            assistantMessageID: UUID(), assistantText: "收到", completedAt: reinforcedAt
        )
        _ = try await store.applyMemoryOperations([
            .reinforce(existingMemoryID: added.id, importance: 0.8, confidence: 0.95)
        ], for: reinforcement, extractorVersion: 1, modelName: "test", now: reinforcedAt.addingTimeInterval(7_200))
        let reinforced = try await store.memory(id: added.id, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(reinforced?.lastConfirmedAt, reinforcedAt)
    }

    private func insert(
        _ store: MemoryStore,
        kind: MemoryKind = .preference,
        text: String,
        importance: Double = 0.5,
        embedding: Data? = nil,
        status: MemoryStatus = .active,
        expiresAt: Date? = nil,
        now: Date
    ) async throws -> MemoryItemSnapshot {
        try await store.insertMemory(scopeID: MemoryScope.localDefault, draft: .init(
            kind: kind, canonicalText: text, embeddingData: embedding, importance: importance,
            status: status, createdAt: now, updatedAt: now, lastConfirmedAt: now, expiresAt: expiresAt
        ))
    }

    private func envelope(_ values: [Float], descriptor: MemoryEmbeddingDescriptor, text: String) throws -> Data {
        try MemoryEmbeddingEnvelope(result: .init(descriptor: descriptor, values: values), text: text).encoded()
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        let configuration = ModelConfiguration("MemoryRetrievalTests", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

private actor TestSemanticResolver: MemorySemanticEmbeddingResolving {
    static let descriptor = MemoryEmbeddingDescriptor(
        provider: "test-semantic", modelIdentifier: "test-v1", revision: 1, dimension: 2,
        modelFamily: "test", language: "zh-Hans", semantic: true
    )

    func descriptor(for text: String) -> MemoryEmbeddingDescriptor? { Self.descriptor }

    func embedding(for text: String) throws -> MemoryEmbeddingVector {
        try .init(descriptor: Self.descriptor, values: text.contains("弱相关") ? [0, 1] : [1, 0])
    }
}
