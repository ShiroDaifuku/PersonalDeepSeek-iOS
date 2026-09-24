import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \LocalKnowledgeBase.createdAt) private var knowledgeBases: [LocalKnowledgeBase]
    @AppStorage("defaultModel") private var defaultModel = "deepseek-flash"
    @AppStorage("thinkingEnabled") private var thinking = true
    @AppStorage("reasoningEffort") private var effort = "high"
    @AppStorage("cloudServiceURL") private var cloudServiceURL = CloudServiceDefaults.baseURL
    @AppStorage("opaqueUserID") private var userID = ""
    @State private var current: Conversation?
    @State private var input = ""
    @State private var isStreaming = false
    @State private var errorText: String?
    @State private var toolStatus: String?
    @State private var streamTask: Task<Void, Never>?
    @State private var showingConversations = false
    @State private var showingConversationSettings = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var attachments: [PendingAttachment] = []
    @State private var showingFilePicker = false
    @State private var showingCamera = false
    @State private var attachmentError: String?
    @State private var pendingTaskAction: PendingTaskAction?

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = current {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(conversation.messages.sorted { $0.createdAt < $1.createdAt }) { message in MessageBubble(message: message) }
                        if isStreaming, conversation.messages.last?.content.isEmpty == true, conversation.messages.last?.reasoning.isEmpty == true {
                            HStack { ProgressView().controlSize(.small); Text(toolStatus ?? "正在思考…").font(.callout).foregroundStyle(.secondary); Spacer() }.padding(.horizontal)
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 16)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .background(Color(.systemGroupedBackground))
            } else { ContentUnavailableView("开始对话", systemImage: "sparkles", description: Text("对话、知识库和研究都在这台设备上编排。")) }
            if let toolStatus, isStreaming {
                Label(toolStatus, systemImage: "wand.and.stars").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorText { Text(errorText).foregroundStyle(.red).font(.caption).padding(.horizontal) }
            if !attachments.isEmpty { AttachmentStrip(attachments: attachments) { id in attachments.removeAll { $0.id == id } } }
            composer
        }
        .navigationTitle(current?.title ?? "DeepSeek").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingConversations = true } label: { Image(systemName: "sidebar.left") }.accessibilityLabel("会话列表")
                Menu { ForEach(["deepseek-flash", "deepseek-v4-pro"], id: \.self) { value in Button(value) { defaultModel = value; current?.model = value } } } label: { Image(systemName: "cpu") }.accessibilityLabel("选择模型")
                if current != nil { Button { showingConversationSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("会话设置") }
                Button { createConversation() } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("新对话")
            }
        }
        .onAppear { current = conversations.first; openPendingConversationIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, isStreaming, let current { LiveActivityManager.shared.start(title: current.title, kind: "generation", detail: toolStatus ?? "正在生成回答") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepSeekNotificationRoute)) { _ in openPendingConversationIfNeeded() }
        .sheet(isPresented: $showingConversations) { ConversationListView(selection: $current, defaultModel: defaultModel) }
        .sheet(isPresented: $showingConversationSettings) { if let current { ConversationSettingsView(conversation: current) } }
        .sheet(item: $pendingTaskAction) { action in TaskToolConfirmationView(action: action, onConfirm: { confirmTask(action) }, onCancel: { cancelTask(action) }) }
        .fullScreenCover(isPresented: $showingCamera) { CameraPicker { data in if let data, let value = PendingAttachment.image(data: data, name: "camera.jpg") { attachments.append(value) } } }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.image, .plainText, .json, .pdf], allowsMultipleSelection: true) { result in importFiles(result) }
        .onChange(of: photoSelection) { _, selection in loadPhotos(selection) }
        .alert("无法添加附件", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) { Button("好") {} } message: { Text(attachmentError ?? "") }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                PhotosPicker(selection: $photoSelection, maxSelectionCount: 6, matching: .images) { Label("照片图库", systemImage: "photo.on.rectangle") }
                Button { requestCamera() } label: { Label("拍照", systemImage: "camera") }
                Button { showingFilePicker = true } label: { Label("选取文件", systemImage: "doc") }
            } label: { Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 34, height: 34).background(.thinMaterial, in: Circle()) }.disabled(isStreaming)
            TextField("询问任何问题", text: $input, axis: .vertical).lineLimit(1...6).padding(.horizontal, 13).padding(.vertical, 9).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button { if isStreaming { streamTask?.cancel() } else { send() } } label: {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white).frame(width: 36, height: 36).background(isStreaming ? Color.red : Color.accentColor, in: Circle())
            }.disabled(!isStreaming && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty).accessibilityLabel(isStreaming ? "停止生成" : "发送")
        }.padding(.horizontal, 12).padding(.vertical, 10).background(.bar)
    }

    private var taskAPI: TaskAPI? { guard let url = URL(string: cloudServiceURL), !userID.isEmpty else { return nil }; return TaskAPI(base: url, userID: userID) }

    @MainActor private func createConversation() { let value = Conversation(model: defaultModel); context.insert(value); current = value; try? context.save() }
    private func openPendingConversationIfNeeded() {
        guard let id = UserDefaults.standard.string(forKey: "pendingConversationID"), let uuid = UUID(uuidString: id), let conversation = conversations.first(where: { $0.id == uuid }) else { return }
        UserDefaults.standard.removeObject(forKey: "pendingConversationID"); current = conversation
    }

    private func send() {
        let typedText = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedText.isEmpty || !attachments.isEmpty else { return }
        let fileSections = attachments.compactMap { item -> String? in guard let text = item.textContent else { return nil }; return "\n\n--- 文件：\(item.name) ---\n\(text)" }.joined()
        let displayText = typedText.isEmpty ? (attachments.allSatisfy(\.isImage) ? "请分析所附图片" : "请分析所附文件") : typedText
        let requestText = displayText + fileSections
        let imageDataURLs = attachments.filter(\.isImage).map(\.dataURL)
        if current == nil { createConversation() }; guard let conversation = current else { return }
        let history = conversation.messages.sorted { $0.createdAt < $1.createdAt }
        let attachmentNames = attachments.map(\.name)
        let visibleText = displayText + (attachmentNames.isEmpty ? "" : "\n📎 " + attachmentNames.joined(separator: "、"))
        let user = ChatMessage(role: "user", content: visibleText, conversation: conversation), assistant = ChatMessage(role: "assistant", conversation: conversation)
        context.insert(user); context.insert(assistant); input = ""; attachments = []; photoSelection = []; isStreaming = true; errorText = nil; toolStatus = "正在判断是否需要工具…"
        if conversation.title == "新对话" { conversation.title = String(displayText.prefix(24)) }
        let planningMessages = MessagePrefix.stable(system: conversation.systemPrompt, history: history, newUserText: requestText, imageDataURLs: imageDataURLs)
        streamTask = Task {
            do {
                let tasks = (try? await taskAPI?.list()) ?? []
                let preferredTool = AssistantIntentRouter.preferredTool(for: requestText)
                let calls: [AssistantToolCall]
                do { calls = try await AssistantToolPlanner().plan(messages: planningMessages, model: conversation.model, tasks: tasks, preferredTool: preferredTool) }
                catch {
                    if preferredTool != nil { throw NSError(domain: "AssistantTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "工具规划失败：\(error.localizedDescription)"] ) }
                    calls = []
                }
                var referenceSections: [String] = []
                for call in calls {
                    try Task.checkCancellation()
                    switch call {
                    case .searchKnowledge(let query, let limit):
                        toolStatus = "正在检索本地知识库…"
                        let results = LocalKnowledgeIndex.search(query, in: knowledgeBases, limit: limit)
                        if !results.isEmpty { referenceSections.append("Local knowledge:\n" + LocalKnowledgeIndex.context(from: results)) }
                    case .deepResearch(let query):
                        toolStatus = "正在搜索并抓取可靠来源…"
                        LiveActivityManager.shared.start(title: conversation.title, kind: "research", detail: "正在进行深度研究")
                        let sources = try await LocalResearchService().gather(query: query)
                        referenceSections.append("Web research evidence:\n" + LocalResearchService.evidencePrompt(question: query, sources: sources))
                    case .createTask(let draft): pendingTaskAction = .init(mode: .create, draft: draft, enabled: true)
                    case .editTask(let taskID, let draft, let enabled):
                        guard let task = tasks.first(where: { $0.id == taskID }) else { throw NSError(domain: "AssistantTools", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到要编辑的定时任务，请先打开任务页刷新。"] ) }
                        pendingTaskAction = .init(mode: .edit(task), draft: draft, enabled: enabled)
                    }
                }
                if pendingTaskAction != nil { assistant.content = "我已经整理好定时任务变更。请在确认页核对时间、时区、提示词、联网工具和通知设置；确认前不会保存。" }
                else {
                    toolStatus = referenceSections.isEmpty ? "正在生成回答…" : "工具执行完成，正在整理回答…"
                    let requestMessages = MessagePrefix.stable(system: conversation.systemPrompt, history: history, knowledgeContext: referenceSections.joined(separator: "\n\n"), newUserText: requestText, imageDataURLs: imageDataURLs)
                    for try await delta in APIClient().stream(messages: requestMessages, model: conversation.model, thinking: thinking, reasoningEffort: effort) { switch delta { case .reasoning(let value): assistant.reasoning += value; case .content(let value): assistant.content += value; default: break } }
                }
            } catch is CancellationError {
                // Preserve partial output when explicitly stopped.
            } catch { if assistant.content.isEmpty && assistant.reasoning.isEmpty { context.delete(assistant) }; errorText = error.localizedDescription }
            await LiveActivityManager.shared.finish(detail: assistant.content.isEmpty ? "生成已停止" : "回答已完成", success: !assistant.content.isEmpty)
            finishGeneration()
        }
    }

    @MainActor private func finishGeneration() {
        isStreaming = false; streamTask = nil; toolStatus = nil; try? context.save()
        AppGroupSnapshotStore.updateConversations(conversations.map { value in let preview = value.messages.sorted { $0.createdAt < $1.createdAt }.last?.content ?? ""; return .init(id: value.id.uuidString, title: value.title, preview: String(preview.prefix(120))) })
    }

    private func confirmTask(_ action: PendingTaskAction) {
        guard let api = taskAPI else { errorText = "请先在设置中填写云端任务访问令牌"; pendingTaskAction = nil; return }
        let snapshot = LocalKnowledgeIndex.attachingContext(to: action.draft, results: LocalKnowledgeIndex.search(action.draft.prompt, in: knowledgeBases, limit: 4))
        Task {
            do {
                switch action.mode { case .create: _ = try await api.create(snapshot); case .edit(let task): _ = try await api.update(task, draft: snapshot, enabled: action.enabled) }
                appendAssistant(action.mode == .create ? "定时任务已创建。你可以在“任务”页暂停、编辑或查看执行记录。" : "定时任务已更新。")
            } catch { errorText = error.localizedDescription }
            pendingTaskAction = nil
        }
    }

    private func cancelTask(_ action: PendingTaskAction) { pendingTaskAction = nil; appendAssistant(action.mode == .create ? "已取消创建定时任务。" : "已取消编辑定时任务。") }
    @MainActor private func appendAssistant(_ text: String) { guard let current else { return }; context.insert(ChatMessage(role: "assistant", content: text, conversation: current)); try? context.save() }

    private func loadPhotos(_ selection: [PhotosPickerItem]) {
        Task { var loaded: [PendingAttachment] = []; for (index, item) in selection.enumerated() { if let data = try? await item.loadTransferable(type: Data.self), let attachment = PendingAttachment.image(data: data, name: "photo-\(index + 1).jpg") { loaded.append(attachment) } }; attachments.append(contentsOf: loaded); photoSelection = [] }
    }
    private func requestCamera() { Task { guard UIImagePickerController.isSourceTypeAvailable(.camera) else { attachmentError = "当前设备没有可用相机。"; return }; if await CameraAuthorization.request() { showingCamera = true } else { attachmentError = "请在系统设置中允许相机权限。" } } }
    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                let accessing = url.startAccessingSecurityScopedResource(); defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: .mappedIfSafe); guard data.count <= 10 * 1_024 * 1_024 else { throw NSError(domain: "Attachment", code: 1, userInfo: [NSLocalizedDescriptionKey: "单个文件不能超过 10 MB。"] ) }
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .image) == true, let value = PendingAttachment.image(data: data, name: url.lastPathComponent) { attachments.append(value) }
                else if type?.conforms(to: .plainText) == true || type == .json { attachments.append(.init(name: url.lastPathComponent, mimeType: type == .json ? "application/json" : "text/plain", data: data)) }
                else { throw NSError(domain: "Attachment", code: 2, userInfo: [NSLocalizedDescriptionKey: "PDF 等文档请上传到知识库；聊天附件当前支持图片、文本和 JSON。"] ) }
            }
        } catch { attachmentError = error.localizedDescription }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == "user" }
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 44) }
            if !isUser { Image(systemName: "sparkles").foregroundStyle(.tint).frame(width: 28, height: 28).background(.thinMaterial, in: Circle()).accessibilityHidden(true) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    if !message.reasoning.isEmpty { DisclosureGroup("思考过程") { Text(message.reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) } }
                    if isUser {
                        if let rendered = try? AttributedString(markdown: message.content) { Text(rendered).textSelection(.enabled) } else { Text(message.content).textSelection(.enabled) }
                    } else { RichMessageView(text: message.content) }
                }.padding(.horizontal, 13).padding(.vertical, 10).foregroundStyle(isUser ? Color.white : Color.primary).background(isUser ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                HStack(spacing: 14) { Button { UIPasteboard.general.string = message.content } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制消息"); ShareLink(item: message.content) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享消息") }.font(.caption).foregroundStyle(.secondary)
            }
            if !isUser { Spacer(minLength: 24) }
        }.frame(maxWidth: .infinity).accessibilityElement(children: .contain)
    }
}

private struct TaskToolConfirmationView: View {
    let action: PendingTaskAction
    let onConfirm: () -> Void
    let onCancel: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section(action.mode == .create ? "AI 建议创建任务" : "AI 建议编辑任务") {
                    LabeledContent("标题", value: action.draft.title); LabeledContent("类型", value: action.draft.kind); LabeledContent("计划", value: action.draft.schedule.expression); LabeledContent("时区", value: action.draft.schedule.timezone); LabeledContent("状态", value: action.enabled ? "启用" : "暂停"); LabeledContent("通知", value: action.draft.notify ? "开启" : "关闭")
                }
                Section("执行提示词") { Text(action.draft.prompt).textSelection(.enabled) }
                Section("工具") { Text(action.draft.tools.joined(separator: "、")) }
                Section { Text("确认后才会写入云端。若引用本地知识库，只上传本次检索到的少量相关片段。") }.font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("确认定时任务").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel, action: onCancel) }; ToolbarItem(placement: .confirmationAction) { Button("确认保存", action: onConfirm) } }
        }
    }
}
