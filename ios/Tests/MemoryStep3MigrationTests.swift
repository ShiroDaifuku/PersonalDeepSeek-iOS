import Foundation
import SwiftData
import XCTest
@testable import PersonalDeepSeek

@MainActor
final class MemoryStep3MigrationTests: XCTestCase {
    func testPreStep3StoreAddsLastConfirmedAtWithoutLosingMemoryOrSource() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_STEP3_MIGRATION_VALIDATION"] == "1",
            "Requires generated pre-Step-3 SwiftData fixture"
        )
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "pre-step3", withExtension: "store"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("step3-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copied = directory.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: fixture, to: copied)

        let schema = Schema([UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self])
        let configuration = ModelConfiguration("Default", schema: schema, url: copied, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemoryItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemorySource>()), 1)

        let store = MemoryStore(modelContainer: container)
        let values = try await store.listMemories(scopeID: MemoryScope.localDefault)
        let migrated = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(migrated.id, UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        XCTAssertEqual(migrated.canonicalText, "用户偏好保留旧数据库中的记忆。")
        XCTAssertEqual(migrated.lastConfirmedAt, migrated.createdAt)
        let sources = try await store.sources(memoryItemID: migrated.id, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.turnFingerprint, "pre-step3-turn")
    }
}
