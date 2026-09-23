import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

enum AppGroupSnapshotStore {
    static let suiteName = "group.local.personal.deepseek"
    private static let key = "widgetSnapshot.v1"

    static func load() -> SharedSnapshot {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(SharedSnapshot.self, from: data) else { return .empty }
        return value
    }

    static func save(_ value: SharedSnapshot) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    static func updateConversations(_ values: [SharedSnapshot.ConversationSummary]) {
        var current = load(); current.conversations = Array(values.prefix(4)); current.updatedAt = Date(); save(current)
    }

    static func updateTasks(_ values: [SharedSnapshot.TaskSummary]) {
        var current = load(); current.tasks = Array(values.prefix(4)); current.updatedAt = Date(); save(current)
    }
}
