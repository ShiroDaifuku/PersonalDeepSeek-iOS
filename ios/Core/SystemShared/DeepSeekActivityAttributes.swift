import Foundation
import ActivityKit

/// Shared by the app and widget extension. Keep this type source-compatible in both targets.
struct DeepSeekActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var detail: String
        var progress: Double
    }

    var operationID: String
    var title: String
    var kind: String
}

struct SharedSnapshot: Codable, Equatable {
    struct ConversationSummary: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var preview: String
    }
    struct TaskSummary: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var nextRunAt: String?
        var enabled: Bool
    }

    var conversations: [ConversationSummary]
    var tasks: [TaskSummary]
    var updatedAt: Date

    static let empty = SharedSnapshot(conversations: [], tasks: [], updatedAt: .distantPast)
}
