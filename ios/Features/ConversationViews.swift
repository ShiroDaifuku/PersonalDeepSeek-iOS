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
            AssistantHeroCard(isThinking: isThinking, isPlaying: animationActive)
                .padding(.horizontal, 12).padding(.bottom, 12)
            Button { create() } label: {
                Label("开启新对话", systemImage: "plus")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        LinearGradient(colors: [Color(red: 0.18, green: 0.55, blue: 1), Color(red: 0.08, green: 0.38, blue: 0.92)], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }.buttonStyle(.plain).padding(.horizontal, 12)
            TextField("搜索历史对话", text: $search).textFieldStyle(.roundedBorder).padding(12)
            List {
                if !regularConversations.isEmpty { Section("最近对话") { conversationRows(regularConversations) } }
                if !researchConversations.isEmpty { Section("深度研究") { conversationRows(researchConversations) } }
                if filtered.isEmpty { ContentUnavailableView("暂无会话", systemImage: "bubble.left.and.bubble.right") }
            }
            .listStyle(.plain)
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

private struct AssistantHeroCard: View {
    let isThinking: Bool
    let isPlaying: Bool

    var body: some View {
        MascotVideoView(mode: .idle, isPlaying: isPlaying)
            .aspectRatio(960.0 / 492.0, contentMode: .fit)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI ASSISTANT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .tracking(0.8)
                    Text("DS 娘")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Circle().fill(isThinking ? Color.cyan : Color.green).frame(width: 7, height: 7)
                        Text(isThinking ? "正在思考" : "随时待命")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    Text("陪你对话、搜索和整理资料")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .frame(maxWidth: 126, alignment: .leading)
                }
                .padding(.leading, 18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: Color.indigo.opacity(0.2), radius: 12, y: 6)
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
