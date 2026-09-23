import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @AppStorage("connectionMode") private var mode = ConnectionMode.proxy.rawValue
    @AppStorage("proxyURL") private var proxyURL = "http://127.0.0.1:8787/"
    @AppStorage("opaqueUserID") private var userID = ""
    @AppStorage("defaultModel") private var defaultModel = "deepseek-flash"
    @AppStorage("thinkingEnabled") private var thinking = true
    @AppStorage("reasoningEffort") private var effort = "high"
    @State private var current: Conversation?
    @State private var input = ""
    @State private var isStreaming = false
    @State private var errorText: String?
    @State private var streamTask: Task<Void, Never>?
    @State private var showingConversations = false
    @State private var showingConversationSettings = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var attachments: [PendingAttachment] = []
    @State private var showingFilePicker = false
    @State private var showingCamera = false
    @State private var attachmentError: String?

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = current {
                List(conversation.messages.sorted { $0.createdAt < $1.createdAt }) { message in MessageRow(message: message) }
                    .listStyle(.plain)
            } else { ContentUnavailableView("开始对话", systemImage: "bubble.left", description: Text("消息仅保存在本机 SwiftData。")) }
            if let errorText { Text(errorText).foregroundStyle(.red).font(.caption).padding(.horizontal) }
            if !attachments.isEmpty { AttachmentStrip(attachments: attachments) { id in attachments.removeAll { $0.id == id } } }
            HStack(alignment: .bottom) {
                Menu {
                    PhotosPicker(selection: $photoSelection, maxSelectionCount: 6, matching: .images) { Label("照片图库", systemImage: "photo.on.rectangle") }
                    Button { requestCamera() } label: { Label("拍照", systemImage: "camera") }
                    Button { showingFilePicker = true } label: { Label("选取文件", systemImage: "doc") }
                } label: { Image(systemName: "plus.circle").font(.title2) }
                .disabled(isStreaming)
                TextField("发送消息", text: $input, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...6)
                Button { if isStreaming { streamTask?.cancel() } else { send() } } label: { Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill").font(.title2) }
                    .disabled(!isStreaming && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
            }.padding()
        }
        .navigationTitle(current?.title ?? "DeepSeek")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingConversations = true } label: { Image(systemName: "sidebar.left") }.accessibilityLabel("会话列表")
                Menu(defaultModel) { ForEach(["deepseek-flash", "deepseek-v4-pro"], id: \.self) { value in Button(value) { defaultModel = value; current?.model = value } } }
                if current != nil { Button { showingConversationSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("会话设置") }
                Button { createConversation() } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .onAppear { if userID.isEmpty { userID = "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }; current = conversations.first; openPendingConversationIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .deepSeekNotificationRoute)) { _ in openPendingConversationIfNeeded() }
        .sheet(isPresented: $showingConversations) { ConversationListView(selection: $current, defaultModel: defaultModel) }
        .sheet(isPresented: $showingConversationSettings) { if let current { ConversationSettingsView(conversation: current) } }
        .fullScreenCover(isPresented: $showingCamera) { CameraPicker { data in if let data, let value = PendingAttachment.image(data: data, name: "camera.jpg") { attachments.append(value) } } }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.image, .plainText, .json, .pdf], allowsMultipleSelection: true) { result in importFiles(result) }
        .onChange(of: photoSelection) { _, selection in loadPhotos(selection) }
        .alert("无法添加附件", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) { Button("好") {} } message: { Text(attachmentError ?? "") }
    }

    @MainActor private func createConversation() {
        let value = Conversation(model: defaultModel); context.insert(value); current = value; try? context.save()
    }
    private func openPendingConversationIfNeeded() {
        guard let id = UserDefaults.standard.string(forKey: "pendingConversationID"), let uuid = UUID(uuidString: id),
              let conversation = conversations.first(where: { $0.id == uuid }) else { return }
        UserDefaults.standard.removeObject(forKey: "pendingConversationID")
        current = conversation
    }
    private func send() {
        let typedText = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedText.isEmpty || !attachments.isEmpty else { return }
        let fileSections = attachments.compactMap { item -> String? in
            guard let text = item.textContent else { return nil }
            return "\n\n--- 文件：\(item.name) ---\n\(text)"
        }.joined()
        let displayText = typedText.isEmpty ? (attachments.allSatisfy(\.isImage) ? "请分析所附图片" : "请分析所附文件") : typedText
        let requestText = displayText + fileSections
        let imageDataURLs = attachments.filter(\.isImage).map(\.dataURL)
        if current == nil { createConversation() }; guard let conversation = current else { return }
        let history = conversation.messages.sorted { $0.createdAt < $1.createdAt }
        let requestMessages = MessagePrefix.stable(system: conversation.systemPrompt, history: history, newUserText: requestText, imageDataURLs: imageDataURLs)
        let attachmentNames = attachments.map(\.name)
        let visibleText = displayText + (attachmentNames.isEmpty ? "" : "\n📎 " + attachmentNames.joined(separator: "、"))
        let user = ChatMessage(role: "user", content: visibleText, conversation: conversation); let assistant = ChatMessage(role: "assistant", conversation: conversation)
        context.insert(user); context.insert(assistant); input = ""; attachments = []; photoSelection = []; isStreaming = true; errorText = nil
        if conversation.title == "新对话" { conversation.title = String(displayText.prefix(24)) }
        guard let url = URL(string: proxyURL), let selectedMode = ConnectionMode(rawValue: mode) else { errorText = "设置中的代理 URL 无效"; isStreaming = false; return }
        let client = APIClient(configuration: .init(mode: selectedMode, proxyURL: url, userID: userID))
        LiveActivityManager.shared.start(title: conversation.title, kind: "generation", detail: "正在生成回答")
        streamTask = Task {
            do {
                for try await delta in client.stream(messages: requestMessages, model: conversation.model, thinking: thinking, reasoningEffort: effort) {
                    await MainActor.run { switch delta { case .reasoning(let value): assistant.reasoning += value; case .content(let value): assistant.content += value; default: break } }
                }
            } catch is CancellationError {
                // Keep a partial answer, if any, when the person stops generation.
            } catch { await MainActor.run { if assistant.content.isEmpty && assistant.reasoning.isEmpty { context.delete(assistant) }; errorText = error.localizedDescription } }
            await LiveActivityManager.shared.finish(detail: assistant.content.isEmpty ? "生成已停止" : "回答已完成", success: !assistant.content.isEmpty)
            await MainActor.run {
                isStreaming = false; streamTask = nil; try? context.save()
                AppGroupSnapshotStore.updateConversations(conversations.map { value in
                    let preview = value.messages.sorted { $0.createdAt < $1.createdAt }.last?.content ?? ""
                    return .init(id: value.id.uuidString, title: value.title, preview: String(preview.prefix(120)))
                })
            }
        }
    }

    private func loadPhotos(_ selection: [PhotosPickerItem]) {
        Task {
            var loaded: [PendingAttachment] = []
            for (index, item) in selection.enumerated() {
                if let data = try? await item.loadTransferable(type: Data.self), let attachment = PendingAttachment.image(data: data, name: "photo-\(index + 1).jpg") { loaded.append(attachment) }
            }
            await MainActor.run { attachments.append(contentsOf: loaded); photoSelection = [] }
        }
    }

    private func requestCamera() {
        Task {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else { await MainActor.run { attachmentError = "当前设备没有可用相机。" }; return }
            if await CameraAuthorization.request() { await MainActor.run { showingCamera = true } }
            else { await MainActor.run { attachmentError = "请在系统设置中允许相机权限。" } }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 10 * 1_024 * 1_024 else { throw NSError(domain: "Attachment", code: 1, userInfo: [NSLocalizedDescriptionKey: "单个文件不能超过 10 MB。"] ) }
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .image) == true, let value = PendingAttachment.image(data: data, name: url.lastPathComponent) { attachments.append(value) }
                else if type?.conforms(to: .plainText) == true || type == .json { attachments.append(.init(name: url.lastPathComponent, mimeType: type == .json ? "application/json" : "text/plain", data: data)) }
                else { throw NSError(domain: "Attachment", code: 2, userInfo: [NSLocalizedDescriptionKey: "PDF 等文档请上传到知识库；聊天附件当前支持图片、文本和 JSON。"] ) }
            }
        } catch { attachmentError = error.localizedDescription }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role == "user" ? "你" : "DeepSeek").font(.caption).foregroundStyle(.secondary)
            if !message.reasoning.isEmpty { DisclosureGroup("思考过程") { Text(message.reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) } }
            if let rendered = try? AttributedString(markdown: message.content) { Text(rendered).textSelection(.enabled) } else { Text(message.content).textSelection(.enabled) }
            HStack { Button { UIPasteboard.general.string = message.content } label: { Label("复制", systemImage: "doc.on.doc") }; ShareLink(item: message.content) { Label("分享", systemImage: "square.and.arrow.up") } }.font(.caption)
        }.padding(.vertical, 4)
    }
}
