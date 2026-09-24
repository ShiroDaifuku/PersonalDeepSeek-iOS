import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

private enum ComposerToolMode: String, Identifiable {
    case scheduledTask, deepResearch, knowledge
    var id: String { rawValue }
    var title: String { switch self { case .scheduledTask: "创建定时任务"; case .deepResearch: "深度搜索"; case .knowledge: "连接知识库" } }
    var icon: String { switch self { case .scheduledTask: "clock.badge.plus"; case .deepResearch: "sparkle.magnifyingglass"; case .knowledge: "books.vertical" } }
    var preferredTool: String { switch self { case .scheduledTask: "create_scheduled_task"; case .deepResearch: "start_deep_search"; case .knowledge: "search_local_knowledge" } }
}

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
    @State private var pendingKnowledgeAction: PendingKnowledgeAction?
    @State private var knowledgeImportTarget: LocalKnowledgeBase?
    @State private var showingKnowledgeImporter = false
    @State private var manualTool: ComposerToolMode?
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
        VStack(spacing: 0) {
            if let conversation = current {
                let orderedMessages = conversation.messages.sorted { $0.createdAt < $1.createdAt }
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(orderedMessages) { message in
                            MessageBubble(message: message, isStreaming: isStreaming && orderedMessages.last?.id == message.id)
                        }
                        if isStreaming, orderedMessages.last?.content.isEmpty == true, orderedMessages.last?.reasoning.isEmpty == true {
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
            if let manualTool {
                HStack(spacing: 7) { Image(systemName: manualTool.icon); Text(manualTool.title); Button { self.manualTool = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("取消\(manualTool.title)"); Spacer() }
                    .font(.caption.weight(.medium)).foregroundStyle(.tint).padding(.horizontal, 14).padding(.vertical, 6)
            }
            composer
        }
        if showingConversations {
            Color.black.opacity(0.22).ignoresSafeArea().onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showingConversations = false } }
            HStack(spacing: 0) {
                ConversationSidebarView(selection: $current, defaultModel: defaultModel) { withAnimation(.easeOut(duration: 0.2)) { showingConversations = false } }
                    .frame(width: min(UIScreen.main.bounds.width * 0.86, 350)).frame(maxHeight: .infinity).shadow(color: .black.opacity(0.18), radius: 18, x: 8)
                Spacer(minLength: 0)
            }.transition(.move(edge: .leading))
        }
        }
        .navigationTitle(current?.title ?? "DeepSeek").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { composerFocused = false; withAnimation(.easeOut(duration: 0.2)) { showingConversations.toggle() } } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("展开对话侧栏") }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu { ForEach(["deepseek-flash", "deepseek-v4-pro"], id: \.self) { value in Button(value) { defaultModel = value; current?.model = value } } } label: { Image(systemName: "cpu") }.accessibilityLabel("选择模型")
                if current != nil { Button { showingConversationSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("会话设置") }
            }
        }
        .onAppear { current = conversations.first; openPendingConversationIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, isStreaming, let current { LiveActivityManager.shared.start(title: current.title, kind: "generation", detail: toolStatus ?? "正在生成回答") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepSeekNotificationRoute)) { _ in openPendingConversationIfNeeded() }
        .sheet(isPresented: $showingConversationSettings) { if let current { ConversationSettingsView(conversation: current) } }
        .sheet(item: $pendingTaskAction) { action in TaskToolConfirmationView(action: action, onConfirm: { confirmTask(action) }, onCancel: { cancelTask(action) }) }
        .sheet(item: $pendingKnowledgeAction) { pending in KnowledgeToolConfirmationView(pending: pending, onConfirm: { confirmKnowledge(pending) }, onCancel: { pendingKnowledgeAction = nil }) }
        .fullScreenCover(isPresented: $showingCamera) { CameraPicker { data in if let data, let value = PendingAttachment.image(data: data, name: "camera.jpg") { attachments.append(value) } } }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.image, .plainText, .json, .pdf], allowsMultipleSelection: true) { result in importFiles(result) }
        .fileImporter(isPresented: $showingKnowledgeImporter, allowedContentTypes: [.pdf, .plainText, .json, .commaSeparatedText, .xml], allowsMultipleSelection: true) { result in importKnowledgeFiles(result) }
        .onChange(of: photoSelection) { _, selection in loadPhotos(selection) }
        .alert("无法添加附件", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) { Button("好") {} } message: { Text(attachmentError ?? "") }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                Section("本次对话工具") {
                    Button { selectManualTool(.scheduledTask) } label: { Label("创建定时任务", systemImage: "clock.badge.plus") }
                    Button { selectManualTool(.deepResearch) } label: { Label("开始深度搜索", systemImage: "sparkle.magnifyingglass") }
                    Button { selectManualTool(.knowledge) } label: { Label("连接知识库", systemImage: "books.vertical") }
                }
                Section("添加内容") {
                PhotosPicker(selection: $photoSelection, maxSelectionCount: 6, matching: .images) { Label("照片图库", systemImage: "photo.on.rectangle") }
                Button { requestCamera() } label: { Label("拍照", systemImage: "camera") }
                Button { showingFilePicker = true } label: { Label("选取文件", systemImage: "doc") }
                }
            } label: { Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 34, height: 34).background(.thinMaterial, in: Circle()) }.disabled(isStreaming)
            TextField(manualTool?.title ?? "询问任何问题", text: $input, axis: .vertical).lineLimit(1...6).focused($composerFocused).padding(.horizontal, 13).padding(.vertical, 9).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button { if isStreaming { streamTask?.cancel() } else { composerFocused = false; send() } } label: {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white).frame(width: 36, height: 36).background(isStreaming ? Color.red : Color.accentColor, in: Circle())
            }.disabled(!isStreaming && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty).accessibilityLabel(isStreaming ? "停止生成" : "发送")
        }.padding(.horizontal, 12).padding(.vertical, 10).background(.bar)
    }

    private var taskAPI: TaskAPI? { guard let url = URL(string: cloudServiceURL), !userID.isEmpty else { return nil }; return TaskAPI(base: url, userID: userID) }

    @MainActor private func selectManualTool(_ tool: ComposerToolMode) {
        manualTool = tool
        if tool == .deepResearch {
            if current == nil { createConversation(mode: "research") } else { current?.mode = "research"; try? context.save() }
        }
        composerFocused = true
    }

    @MainActor private func createConversation(mode: String = "chat") { let value = Conversation(model: defaultModel, mode: mode); context.insert(value); current = value; try? context.save() }
    private func openPendingConversationIfNeeded() {
        guard let id = UserDefaults.standard.string(forKey: "pendingConversationID"), let uuid = UUID(uuidString: id), let conversation = conversations.first(where: { $0.id == uuid }) else { return }
        UserDefaults.standard.removeObject(forKey: "pendingConversationID"); current = conversation
    }

    private func send() {
        composerFocused = false
        let typedText = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedText.isEmpty || !attachments.isEmpty else { return }
        let fileSections = attachments.compactMap { item -> String? in guard let text = item.textContent else { return nil }; return "\n\n--- 文件：\(item.name) ---\n\(text)" }.joined()
        let displayText = typedText.isEmpty ? (attachments.allSatisfy(\.isImage) ? "请分析所附图片" : "请分析所附文件") : typedText
        let requestText = displayText + fileSections
        let imageDataURLs = attachments.filter(\.isImage).map(\.dataURL)
        let selectedManualTool = manualTool
        if current == nil { createConversation() }; guard let conversation = current else { return }
        if selectedManualTool == .deepResearch { conversation.mode = "research" }
        let history = conversation.messages.sorted { $0.createdAt < $1.createdAt }
        let attachmentNames = attachments.map(\.name)
        let visibleText = displayText + (attachmentNames.isEmpty ? "" : "\n📎 " + attachmentNames.joined(separator: "、"))
        let user = ChatMessage(role: "user", content: visibleText, conversation: conversation), assistant = ChatMessage(role: "assistant", conversation: conversation)
        context.insert(user); context.insert(assistant); input = ""; attachments = []; photoSelection = []; manualTool = nil; isStreaming = true; errorText = nil; toolStatus = selectedManualTool == nil ? "正在判断是否需要工具…" : "正在准备\(selectedManualTool!.title)…"
        if conversation.title == "新对话" { conversation.title = String(displayText.prefix(24)) }
        let planningMessages = MessagePrefix.stable(system: conversation.systemPrompt, history: history, newUserText: requestText, imageDataURLs: imageDataURLs)
        streamTask = Task {
            do {
                let tasks = (try? await taskAPI?.list()) ?? []
                let preferredTool = selectedManualTool?.preferredTool ?? AssistantIntentRouter.preferredTool(for: requestText)
                let calls: [AssistantToolCall]
                let knowledgeDescriptors = LocalKnowledgeCloudSync.descriptors(from: knowledgeBases)
                do { calls = try await AssistantToolPlanner().plan(messages: planningMessages, model: conversation.model, tasks: tasks, knowledgeBases: knowledgeDescriptors, preferredTool: preferredTool) }
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
                        conversation.mode = "research"
                        LiveActivityManager.shared.start(title: conversation.title, kind: "research", detail: "正在进行深度研究")
                        let sources = try await LocalResearchService().gather(query: query)
                        referenceSections.append("Web research evidence:\n" + LocalResearchService.evidencePrompt(question: query, sources: sources))
                    case .createTask(let draft): pendingTaskAction = .init(mode: .create, draft: draft, enabled: true)
                    case .editTask(let taskID, let draft, let enabled):
                        guard let task = tasks.first(where: { $0.id == taskID }) else { throw NSError(domain: "AssistantTools", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到要编辑的定时任务，请先打开任务页刷新。"] ) }
                        pendingTaskAction = .init(mode: .edit(task), draft: draft, enabled: enabled)
                    case .manageKnowledge(let action):
                        try prepareKnowledgeAction(action, assistant: assistant)
                    }
                }
                if pendingTaskAction != nil { assistant.content = "我已经整理好定时任务变更。请在确认页核对时间、时区、提示词、联网工具、知识库和通知设置；确认前不会保存。" }
                else if pendingKnowledgeAction != nil { assistant.content = "我已经准备好知识库变更，请在确认页核对；确认前不会修改本地资料。" }
                else if showingKnowledgeImporter { assistant.content = "请选择要导入的文件；文件会在本机解析并建立索引。" }
                else if !assistant.content.isEmpty { /* Immediate local tool result is already complete. */ }
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
        Task {
            do {
                switch action.mode { case .create: _ = try await api.create(action.draft); case .edit(let task): _ = try await api.update(task, draft: action.draft, enabled: action.enabled) }
                appendAssistant(action.mode == .create ? "定时任务已创建。你可以在“任务”页暂停、编辑或查看执行记录。" : "定时任务已更新。")
            } catch { errorText = error.localizedDescription }
            pendingTaskAction = nil
        }
    }

    private func cancelTask(_ action: PendingTaskAction) { pendingTaskAction = nil; appendAssistant(action.mode == .create ? "已取消创建定时任务。" : "已取消编辑定时任务。") }
    @MainActor private func appendAssistant(_ text: String) { guard let current else { return }; context.insert(ChatMessage(role: "assistant", content: text, conversation: current)); try? context.save() }

    @MainActor private func prepareKnowledgeAction(_ action: KnowledgeManagementAction, assistant: ChatMessage) throws {
        if action.action == "list" {
            assistant.content = knowledgeBases.isEmpty ? "当前没有知识库。" : knowledgeBases.map { "- \($0.name)：\($0.documents.count) 个文档，\($0.enabled ? "已启用" : "已停用")，\(LocalKnowledgeCloudSync.isEnabled($0.id) ? "已选择云同步" : "仅本机")" }.joined(separator: "\n")
            return
        }
        if action.action == "create" {
            guard !action.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NSError(domain: "KnowledgeTool", code: 400, userInfo: [NSLocalizedDescriptionKey: "知识库名称不能为空。"] ) }
            pendingKnowledgeAction = .init(action: action, currentName: nil); return
        }
        guard let id = UUID(uuidString: action.knowledgeBaseID), let base = knowledgeBases.first(where: { $0.id == id }) else { throw NSError(domain: "KnowledgeTool", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到指定知识库，请让 AI 先列出知识库。"] ) }
        if action.action == "import" { knowledgeImportTarget = base; showingKnowledgeImporter = true; return }
        pendingKnowledgeAction = .init(action: action, currentName: base.name)
    }

    @MainActor private func confirmKnowledge(_ pending: PendingKnowledgeAction) {
        let action = pending.action
        if action.action == "create" {
            context.insert(LocalKnowledgeBase(name: action.name.trimmingCharacters(in: .whitespacesAndNewlines)))
        } else if let id = UUID(uuidString: action.knowledgeBaseID), let base = knowledgeBases.first(where: { $0.id == id }) {
            switch action.action {
            case "rename": base.name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
            case "enable": base.enabled = true
            case "disable": base.enabled = false
            case "delete": LocalKnowledgeCloudSync.setEnabled(false, for: base.id); context.delete(base)
            default: break
            }
        }
        do { try context.save(); appendAssistant("知识库变更已完成。") } catch { errorText = error.localizedDescription }
        pendingKnowledgeAction = nil
        Task { await syncKnowledgeIfConfigured() }
    }

    @MainActor private func importKnowledgeFiles(_ result: Result<[URL], Error>) {
        guard let target = knowledgeImportTarget else { return }
        Task {
            do {
                let urls = try result.get()
                for url in urls { try await LocalKnowledgeImporter.importFile(url, into: target, context: context) }
                appendAssistant("已向“\(target.name)”导入并索引 \(urls.count) 个文件。")
                await syncKnowledgeIfConfigured()
            } catch { errorText = error.localizedDescription }
            knowledgeImportTarget = nil
        }
    }

    @MainActor private func syncKnowledgeIfConfigured() async {
        guard !LocalKnowledgeCloudSync.enabledIDs.isEmpty, let url = URL(string: cloudServiceURL), !userID.isEmpty else { return }
        do { try await KnowledgeSyncAPI(base: url, userID: userID).replaceAll(LocalKnowledgeCloudSync.payloads(from: knowledgeBases)) }
        catch { errorText = "本地变更已保存，但云端知识库同步失败：\(error.localizedDescription)" }
    }

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
    let isStreaming: Bool
    private var isUser: Bool { message.role == "user" }
    var body: some View {
        Group {
            if isUser {
                HStack(alignment: .bottom) {
                    Spacer(minLength: 52)
                    VStack(alignment: .trailing, spacing: 7) {
                        Group { if let rendered = try? AttributedString(markdown: message.content) { Text(rendered) } else { Text(message.content) } }
                            .textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(.white)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        messageActions
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !message.reasoning.isEmpty { ReasoningStrip(reasoning: message.reasoning, isStreaming: isStreaming) }
                    if !message.content.isEmpty { RichMessageView(text: message.content).frame(maxWidth: .infinity, alignment: .leading) }
                    if !message.content.isEmpty { messageActions }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 2)
            }
        }.frame(maxWidth: .infinity).accessibilityElement(children: .contain)
    }

    private var messageActions: some View {
        HStack(spacing: 14) {
            Button { UIPasteboard.general.string = message.content } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制消息")
            ShareLink(item: message.content) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享消息")
        }.font(.caption).foregroundStyle(.secondary)
    }
}

private struct ReasoningStrip: View {
    let reasoning: String
    let isStreaming: Bool
    @State private var expanded: Bool
    init(reasoning: String, isStreaming: Bool) { self.reasoning = reasoning; self.isStreaming = isStreaming; _expanded = State(initialValue: isStreaming) }
    private var characterCount: Int { reasoning.filter { !$0.isWhitespace }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    if isStreaming { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark.circle") }
                    Text("\(isStreaming ? "思考中" : "已思考") · \(characterCount) 字").font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }.foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            if expanded {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        Text(reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id("reasoning-bottom")
                    }
                    .frame(height: 92)
                    .onChange(of: reasoning) { _, _ in proxy.scrollTo("reasoning-bottom", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("reasoning-bottom", anchor: .bottom) }
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.55)).frame(width: 3).padding(.vertical, 8) }
        .onChange(of: isStreaming) { _, active in withAnimation(.easeInOut(duration: 0.2)) { expanded = active } }
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
                if !action.draft.knowledgeBaseIDs.isEmpty { Section("动态知识库") { Text("任务运行时会检索 \(action.draft.knowledgeBaseIDs.count) 个已同步知识库。") } }
                Section { Text("确认后才会写入云端。任务只会访问你在资料库页明确开启并完成同步的知识库。") }.font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("确认定时任务").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel, action: onCancel) }; ToolbarItem(placement: .confirmationAction) { Button("确认保存", action: onConfirm) } }
        }
    }
}

private struct KnowledgeToolConfirmationView: View {
    let pending: PendingKnowledgeAction
    let onConfirm: () -> Void
    let onCancel: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("AI 建议的本地操作") {
                    LabeledContent("操作", value: label)
                    if let currentName = pending.currentName { LabeledContent("知识库", value: currentName) }
                    if !pending.action.name.isEmpty { LabeledContent("新名称", value: pending.action.name) }
                }
                if pending.action.action == "delete" { Section { Label("删除会同时移除其中全部本地文档与索引，且不可撤销。", systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                Section { Text("确认前不会修改任何本地资料；云同步仍只对你手动开启的知识库生效。") }.font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("确认知识库操作")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel, action: onCancel) }; ToolbarItem(placement: .confirmationAction) { Button("确认", role: pending.action.action == "delete" ? .destructive : nil, action: onConfirm) } }
        }
    }
    private var label: String { ["create":"创建", "rename":"重命名", "enable":"启用", "disable":"停用", "delete":"删除"][pending.action.action] ?? pending.action.action }
}
