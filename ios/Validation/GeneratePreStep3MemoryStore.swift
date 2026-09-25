import Foundation
import SwiftData

@Model final class MemoryItem {
    @Attribute(.unique) var id: UUID
    var scopeID: String
    var kindRawValue: String
    var canonicalText: String
    var embeddingData: Data?
    var importance: Double
    var confidence: Double
    var statusRawValue: String
    var createdAt: Date
    var updatedAt: Date
    var lastReinforcedAt: Date?
    var expiresAt: Date?
    var reinforcementCount: Int
    @Relationship(deleteRule: .cascade, inverse: \MemorySource.memoryItem) var sources: [MemorySource]

    init(id: UUID, createdAt: Date) {
        self.id = id
        scopeID = "local-default"
        kindRawValue = "preference"
        canonicalText = "用户偏好保留旧数据库中的记忆。"
        embeddingData = nil
        importance = 0.7
        confidence = 0.9
        statusRawValue = "active"
        self.createdAt = createdAt
        updatedAt = createdAt
        lastReinforcedAt = nil
        expiresAt = nil
        reinforcementCount = 0
        sources = []
    }
}

@Model final class MemorySource {
    @Attribute(.unique) var id: UUID
    var scopeID: String
    var sourceConversationID: UUID
    var userMessageID: UUID?
    var assistantMessageID: UUID?
    var turnFingerprint: String
    var createdAt: Date
    var memoryItem: MemoryItem?

    init(memoryItem: MemoryItem, createdAt: Date) {
        id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        scopeID = "local-default"
        sourceConversationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        userMessageID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        assistantMessageID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        turnFingerprint = "pre-step3-turn"
        self.createdAt = createdAt
        self.memoryItem = memoryItem
    }
}

@main
enum GeneratePreStep3MemoryStore {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw GeneratorError.missingOutputPath }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = Schema([MemoryItem.self, MemorySource.self])
        let configuration = ModelConfiguration("Default", schema: schema, url: output, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        let item = MemoryItem(id: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!, createdAt: createdAt)
        let source = MemorySource(memoryItem: item, createdAt: createdAt)
        item.sources.append(source)
        context.insert(item)
        context.insert(source)
        try context.save()
    }
}

enum GeneratorError: Error { case missingOutputPath }
