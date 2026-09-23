import SwiftUI

struct TaskListView: View {
    @AppStorage("proxyURL") private var proxyURL = "http://127.0.0.1:8787/"
    @AppStorage("opaqueUserID") private var userID = ""
    @State private var tasks: [RemoteTask] = []
    @State private var naturalLanguage = ""
    @State private var draft: TaskDraft?
    @State private var errorText: String?
    @State private var working = false
    @State private var historyTask: RemoteTask?
    @AppStorage("deviceAlarmTaskIDs") private var deviceAlarmTaskIDs = ""
    var body: some View {
        List {
            Section("用自然语言创建") {
                TextField("例如：每天早上九点总结昨日笔记", text: $naturalLanguage, axis: .vertical)
                Button("解析并预览") { parse() }.disabled(naturalLanguage.isEmpty || working)
            }
            if let draft {
                Section("保存前确认") {
                    LabeledContent("标题", value: draft.title); LabeledContent("类型", value: draft.kind)
                    LabeledContent("计划", value: draft.schedule.expression); LabeledContent("时区", value: draft.schedule.timezone)
                    Text(draft.prompt)
                    HStack { Button("确认保存") { confirm(draft) }; Button("取消", role: .cancel) { self.draft = nil } }
                }
            }
            Section("全部任务") {
                ForEach(tasks) { task in
                    VStack(alignment: .leading) { HStack { Text(task.title).font(.headline); Spacer(); Button { toggleAlarm(task) } label: { Image(systemName: alarmIDs.contains(task.id) ? "bell.badge.fill" : "bell") }.buttonStyle(.borderless).accessibilityLabel(alarmIDs.contains(task.id) ? "取消设备强提醒" : "安排设备强提醒"); Button { historyTask = task } label: { Image(systemName: "clock.arrow.circlepath") }.buttonStyle(.borderless).accessibilityLabel("查看执行历史"); Toggle("", isOn: Binding(get: { task.enabled }, set: { toggle(task, $0) })).labelsHidden() }; Text(task.nextRunAt ?? "已暂停").font(.caption).foregroundStyle(.secondary) }
                    .swipeActions { Button("删除", role: .destructive) { remove(task) } }
                }
            }
            if let errorText { Section { Text(errorText).foregroundStyle(.red) } }
        }.navigationTitle("定时任务").refreshable { await load() }.task { await load(); openPendingTaskIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for: .deepSeekNotificationRoute)) { _ in openPendingTaskIfNeeded() }
            .sheet(item: $historyTask) { TaskHistoryView(task: $0) }
    }
    private var api: TaskAPI? { guard let url = URL(string: proxyURL), !userID.isEmpty else { return nil }; return TaskAPI(base: url, userID: userID) }
    private func parse() { guard let api else { errorText = "请先配置代理"; return }; working = true; Task { do { draft = try await api.parse(naturalLanguage) } catch { errorText = error.localizedDescription }; working = false } }
    private func confirm(_ value: TaskDraft) { guard let api else { return }; Task { do { _ = try await api.create(value); draft = nil; naturalLanguage = ""; await load() } catch { errorText = error.localizedDescription } } }
    private func toggle(_ task: RemoteTask, _ enabled: Bool) { guard let api else { return }; Task { do { _ = try await api.setEnabled(task, enabled); await load() } catch { errorText = error.localizedDescription } } }
    private func remove(_ task: RemoteTask) { guard let api else { return }; Task { do { try await api.delete(task); await load() } catch { errorText = error.localizedDescription } } }
    private var alarmIDs: Set<String> { Set(deviceAlarmTaskIDs.split(separator: ",").map(String.init)) }
    private func openPendingTaskIfNeeded() {
        guard let id = UserDefaults.standard.string(forKey: "pendingTaskID"), let task = tasks.first(where: { $0.id == id }) else { return }
        UserDefaults.standard.removeObject(forKey: "pendingTaskID"); historyTask = task
    }
    @MainActor private func toggleAlarm(_ task: RemoteTask) {
        guard let id = UUID(uuidString: task.id) else { errorText = "任务标识无法用于设备强提醒"; return }
        if alarmIDs.contains(task.id) {
            do { try DeviceAlarmService.shared.cancel(id: id); var values = alarmIDs; values.remove(task.id); deviceAlarmTaskIDs = values.sorted().joined(separator: ",") } catch { errorText = error.localizedDescription }
            return
        }
        guard let descriptor = AlarmScheduleParser.parse(taskID: task.id, title: task.title, schedule: task.schedule) else { errorText = "仅支持固定时间的一次性或每周 cron 强提醒"; return }
        Task { do { try await DeviceAlarmService.shared.schedule(descriptor); var values = alarmIDs; values.insert(task.id); deviceAlarmTaskIDs = values.sorted().joined(separator: ",") } catch { errorText = error.localizedDescription } }
    }
    @MainActor private func load() async { guard let api else { return }; do { tasks = try await api.list(); AppGroupSnapshotStore.updateTasks(tasks.map { .init(id: $0.id, title: $0.title, nextRunAt: $0.nextRunAt, enabled: $0.enabled) }); errorText = nil } catch { errorText = error.localizedDescription } }
}

private struct TaskHistoryView: View {
    let task: RemoteTask
    @Environment(\.dismiss) private var dismiss
    @AppStorage("proxyURL") private var proxyURL = "http://127.0.0.1:8787/"
    @AppStorage("opaqueUserID") private var userID = ""
    @State private var runs: [RemoteTaskRun] = []
    @State private var errorText: String?
    private var api: TaskAPI? { guard let url = URL(string: proxyURL), !userID.isEmpty else { return nil }; return TaskAPI(base: url, userID: userID) }
    var body: some View {
        NavigationStack {
            List {
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(run.status).font(.headline); Spacer(); Text(run.model).font(.caption).foregroundStyle(.secondary) }
                        if let output = run.output { Text(output).textSelection(.enabled) }
                        if let error = run.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        if let notification = run.notificationStatus { Text("通知：\(notification)").font(.caption).foregroundStyle(.secondary) }
                        Text("输入约 \(run.promptTokens) · 输出约 \(run.completionTokens) tokens · \(run.startedAt)").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if runs.isEmpty, errorText == nil { ContentUnavailableView("暂无执行记录", systemImage: "clock") }
                if let errorText { Text(errorText).foregroundStyle(.red) }
            }
            .navigationTitle(task.title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await loadAndMarkRead() }
        }
    }
    @MainActor private func loadAndMarkRead() async {
        guard let api else { errorText = "代理配置无效"; return }
        do {
            runs = try await api.runs(task).sorted { $0.startedAt > $1.startedAt }
            for run in runs where !run.read { try await api.markRead(taskID: task.id, runID: run.id) }
            runs = runs.map { value in var copy = value; copy.read = true; return copy }
        } catch { errorText = error.localizedDescription }
    }
}
