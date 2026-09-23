import SwiftUI
import SwiftData

struct ConversationListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @Binding var selection: Conversation?
    let defaultModel: String

    var body: some View {
        NavigationStack {
            List {
                ForEach(conversations) { conversation in
                    Button {
                        selection = conversation; dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conversation.title).foregroundStyle(.primary)
                            Text(conversation.model).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { remove(conversation) }
                    }
                }
                if conversations.isEmpty { ContentUnavailableView("暂无会话", systemImage: "bubble.left.and.bubble.right") }
            }
            .navigationTitle("会话")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { create() } label: { Image(systemName: "square.and.pencil") } }
            }
        }
    }

    private func create() {
        let conversation = Conversation(model: defaultModel); context.insert(conversation); selection = conversation; try? context.save(); dismiss()
    }

    private func remove(_ conversation: Conversation) {
        if selection?.id == conversation.id { selection = conversations.first(where: { $0.id != conversation.id }) }
        context.delete(conversation); try? context.save()
    }
}

struct ConversationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var conversation: Conversation

    var body: some View {
        NavigationStack {
            Form {
                Section("会话") {
                    TextField("标题", text: $conversation.title)
                    TextField("模型名", text: $conversation.model).textInputAutocapitalization(.never)
                }
                Section("自定义指令") {
                    TextEditor(text: $conversation.systemPrompt).frame(minHeight: 180)
                    Text("修改后只影响后续请求。为了提高上下文缓存命中率，请避免频繁修改。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("会话设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { try? context.save(); dismiss() } } }
        }
    }
}
