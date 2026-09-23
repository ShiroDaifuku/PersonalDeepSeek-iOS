import ActivityKit
import SwiftUI
import WidgetKit

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { .init(date: Date(), snapshot: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) { completion(.init(date: Date(), snapshot: AppGroupSnapshotStore.load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: Date(), snapshot: AppGroupSnapshotStore.load())], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct SnapshotEntry: TimelineEntry { let date: Date; let snapshot: SharedSnapshot }

struct PersonalDeepSeekWidget: Widget {
    let kind = "PersonalDeepSeekSummary"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            VStack(alignment: .leading, spacing: 6) {
                Label("DeepSeek", systemImage: "sparkles").font(.headline)
                if let task = entry.snapshot.tasks.first(where: { $0.enabled }) {
                    Text(task.title).lineLimit(1)
                    Text(task.nextRunAt ?? "等待调度").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let chat = entry.snapshot.conversations.first {
                    Text(chat.title).lineLimit(1)
                    Text(chat.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else { Text("打开 App 开始使用").font(.caption).foregroundStyle(.secondary) }
            }.containerBackground(.fill.tertiary, for: .widget)
        }.configurationDisplayName("DeepSeek 摘要").description("显示最近会话或下一项任务。")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct DeepSeekLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeepSeekActivityAttributes.self) { context in
            VStack(alignment: .leading) {
                Text(context.attributes.title).font(.headline)
                Text(context.state.detail).font(.caption).lineLimit(2)
                ProgressView(value: context.state.progress)
            }.padding().activityBackgroundTint(.black.opacity(0.82)).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: context.attributes.kind == "task" ? "clock" : "sparkles") }
                DynamicIslandExpandedRegion(.center) { Text(context.attributes.title).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) { ProgressView(value: context.state.progress); Text(context.state.detail).font(.caption).lineLimit(1) }
            } compactLeading: { Image(systemName: "sparkles") }
              compactTrailing: { Text("\(Int(context.state.progress * 100))%") }
              minimal: { Image(systemName: "sparkles") }
        }
    }
}

@main
struct PersonalDeepSeekWidgetBundle: WidgetBundle {
    var body: some Widget { PersonalDeepSeekWidget(); DeepSeekLiveActivityWidget() }
}
