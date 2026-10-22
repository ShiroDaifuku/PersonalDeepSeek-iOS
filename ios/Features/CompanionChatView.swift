import SwiftUI
import SwiftData

@MainActor
struct CompanionChatView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Query(filter: #Predicate<Conversation> { $0.mode == "companion" }, sort: \Conversation.createdAt, order: .reverse)
    private var conversations: [Conversation]
    @StateObject private var model: CompanionChatViewModel
    @State private var input = ""
    @State private var historyVisible = false
    @FocusState private var focused: Bool
    let active: Bool

    init(memoryService: MemoryService, active: Bool) {
        _model = StateObject(wrappedValue: CompanionChatViewModel(memoryService: memoryService))
        self.active = active
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                MascotVideoView(mode: model.isGenerating ? .thinking : .idle, isPlaying: active && phase == .active)
                    .frame(width: 118, height: 84).clipShape(RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 6) {
                    Text("大福").font(.title2.bold())
                    Text(model.isGenerating ? "正在打字…" : "想说什么就说吧。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("共用全局记忆 · 独立聊天记录").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding().background(.thinMaterial)
            Text("文字陪伴 · 无工具 · 本机生成，退出 App 可能中断")
                .font(.caption2).foregroundStyle(.secondary).padding(.vertical, 6)
            transcript
            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal).accessibilityLabel("聊天状态：\(error)")
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("和大福说句话…", text: $input, axis: .vertical)
                    .lineLimit(1...5).focused($focused).padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                Button {
                    if model.isGenerating { model.cancel() }
                    else { focused = false; model.send(input, context: context); if model.isGenerating { input = "" } }
                } label: {
                    Image(systemName: model.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.body.bold()).foregroundStyle(.white).frame(width: 44, height: 44)
                        .background(model.isGenerating ? Color.red : Color.pink, in: Circle())
                }.disabled(!model.isGenerating && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(model.isGenerating ? "停止大福回复" : "发送给大福")
            }.padding(12).background(.bar)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("陪伴").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { focused = false; historyVisible = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("大福聊天记录")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.select(nil) } label: { Image(systemName: "square.and.pencil") }
                    .disabled(model.isGenerating).accessibilityLabel("和大福开启新对话")
            }
        }
        .sheet(isPresented: $historyVisible) {
            NavigationStack {
                List {
                    Button("开启新对话") { model.select(nil); historyVisible = false }.disabled(model.isGenerating)
                    ForEach(conversations) { conversation in
                        Button { model.select(conversation); historyVisible = false } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(conversation.title).foregroundStyle(.primary)
                                Text(conversation.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(model.isGenerating)
                    }
                }.navigationTitle("大福的聊天记录")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { historyVisible = false } } }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.current == nil {
                        Text("在呢，主人。").foregroundStyle(.secondary).padding(.top, 36)
                    }
                    ForEach(orderedMessages) { message in
                        messageBubbles(message)
                    }
                    if model.isGenerating {
                        bubble(model.streamingText.isEmpty ? "…" : model.streamingText, user: false)
                    }
                    Color.clear.frame(height: 1).id("companion-bottom")
                }.padding(16)
            }.defaultScrollAnchor(.bottom).scrollDismissesKeyboard(.interactively)
                .onChange(of: model.current?.id) { _, _ in proxy.scrollTo("companion-bottom", anchor: .bottom) }
                .onChange(of: model.streamingText) { _, _ in proxy.scrollTo("companion-bottom", anchor: .bottom) }
                .onChange(of: orderedMessages.count) { _, _ in proxy.scrollTo("companion-bottom", anchor: .bottom) }
        }.id(model.current?.id)
    }

    private var orderedMessages: [ChatMessage] {
        (model.current?.messages ?? []).sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    @ViewBuilder
    private func messageBubbles(_ message: ChatMessage) -> some View {
        if !message.content.isEmpty {
            let parts = message.role == "assistant" ? CompanionChatPolicy.segments(message.content) : [message.content]
            ForEach(parts.indices, id: \.self) { index in
                bubble(parts[index], user: message.role == "user")
            }
        }
    }

    private func bubble(_ text: String, user: Bool) -> some View {
        HStack {
            if user { Spacer(minLength: 40) }
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines)).textSelection(.enabled)
                .padding(.horizontal, 15).padding(.vertical, 11)
                .foregroundStyle(user ? Color.white : Color.primary)
                .background(user ? Color.pink : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            if !user { Spacer(minLength: 40) }
        }
    }
}
