import Foundation

enum LocalKnowledgeCloudSync {
    private static let key = "cloudKnowledgeBaseIDs"

    static var enabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: key) }
    }

    static func isEnabled(_ id: UUID) -> Bool { enabledIDs.contains(id.uuidString) }

    static func setEnabled(_ enabled: Bool, for id: UUID) {
        var values = enabledIDs
        if enabled { values.insert(id.uuidString) } else { values.remove(id.uuidString) }
        enabledIDs = values
    }

    @MainActor static func descriptors(from bases: [LocalKnowledgeBase]) -> [KnowledgeBaseToolDescriptor] {
        bases.map { .init(id: $0.id.uuidString, name: $0.name, enabled: $0.enabled, documentCount: $0.documents.count, cloudSyncEnabled: isEnabled($0.id)) }
    }

    @MainActor static func payloads(from bases: [LocalKnowledgeBase]) throws -> [CloudKnowledgeBasePayload] {
        let selected = bases.filter { isEnabled($0.id) }
        let payloads = selected.map { base in
            CloudKnowledgeBasePayload(id: base.id.uuidString, name: base.name, enabled: base.enabled, chunks: base.documents.flatMap { document in
                document.chunks.map { .init(id: $0.id.uuidString, documentName: document.name, index: $0.index, text: $0.text) }
            })
        }
        let chunkCount = payloads.reduce(0) { $0 + $1.chunks.count }
        guard chunkCount <= 2_000 else { throw NSError(domain: "KnowledgeSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "云端同步最多支持 2,000 个资料片段，请减少选择范围。"] ) }
        let encoded = try JSONEncoder().encode(payloads)
        guard encoded.count <= 8_000_000 else { throw NSError(domain: "KnowledgeSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "同步内容超过 8 MB，请减少资料量。"] ) }
        return payloads
    }
}
