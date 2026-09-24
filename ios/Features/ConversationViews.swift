import SwiftUI
import SwiftData

struct ConversationSidebarView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @Binding var selection: Conversation?
    let defaultModel: String
    let isThinking: Bool
    let animationActive: Bool
    let onClose: () -> Void
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("对话").font(.title2.bold())
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭侧栏")
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
            Button { create() } label: {
                Label("开启新对话", systemImage: "square.and.pencil").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).padding(.horizontal, 12)
            TextField("搜索历史对话", text: $search).textFieldStyle(.roundedBorder).padding(12)
            List {
                if !regularConversations.isEmpty { Section("最近对话") { conversationRows(regularConversations) } }
                if !researchConversations.isEmpty { Section("深度研究") { conversationRows(researchConversations) } }
                if filtered.isEmpty { ContentUnavailableView("暂无会话", systemImage: "bubble.left.and.bubble.right") }
            }
            .listStyle(.plain)
            VStack(spacing: 0) {
                MascotVideoView(mode: isThinking ? .thinking : .idle, isPlaying: animationActive)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .frame(maxHeight: 196)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        Label(isThinking ? "思考中" : "待机", systemImage: isThinking ? "brain.head.profile" : "sparkles")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12).padding(.bottom, 10)
        }.background(.regularMaterial)
    }

    @ViewBuilder private func conversationRows(_ values: [Conversation]) -> some View {
        ForEach(values) { conversation in
            Button { selection = conversation; onClose() } label: {
                HStack(spacing: 10) {
                    Image(systemName: conversation.mode == "research" ? "sparkle.magnifyingglass" : "bubble.left")
                        .foregroundStyle(selection?.id == conversation.id ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversation.title).lineLimit(1).foregroundStyle(.primary)
                        Text(conversation.model).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.swipeActions { Button("删除", role: .destructive) { remove(conversation) } }
        }
    }

    private var filtered: [Conversation] { let value = search.trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? conversations : conversations.filter { $0.title.localizedCaseInsensitiveContains(value) || $0.messages.contains(where: { $0.content.localizedCaseInsensitiveContains(value) }) } }
    private var regularConversations: [Conversation] { filtered.filter { $0.mode != "research" } }
    private var researchConversations: [Conversation] { filtered.filter { $0.mode == "research" } }

    private func create() {
        let conversation = Conversation(model: defaultModel); context.insert(conversation); selection = conversation; try? context.save(); onClose()
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
