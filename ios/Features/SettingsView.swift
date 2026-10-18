import SwiftUI

struct SettingsView: View {
    @StateObject private var memoryImport: MemoryBackfillViewModel
    @AppStorage("cloudServiceURL") private var cloudServiceURL = CloudServiceDefaults.baseURL
    @AppStorage("defaultModel") private var model = "deepseek-flash"
    @AppStorage("thinkingEnabled") private var thinking = true
    @AppStorage("reasoningEffort") private var effort = "high"
    @AppStorage("opaqueUserID") private var userID = ""
    @AppStorage("interactiveWebProvider") private var webProvider = WebSearchProviderChoice.deepSeek.rawValue
    @AppStorage("deepSeekWebUsesChatKey") private var reuseChatKey = true
    @State private var editing: CredentialSlot?
    @State private var chatMask = "未设置"
    @State private var webMask = "未设置"
    @State private var cloudMask = "未设置"
    @State private var braveMask = "未设置"
    @State private var cloudExpanded = false
    @State private var checking = false
    @State private var connectionStatus: String?
    @State private var notificationStatus: String?

    init(memoryService: MemoryService) {
        _memoryImport = StateObject(wrappedValue: MemoryBackfillViewModel(memoryService: memoryService))
    }

    var body: some View {
        Form {
            Section {
                Label("个人测试版", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Text("聊天和图片直接连接 DeepSeek；后台定时任务单独使用云端服务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("聊天与图片") {
                credentialRow(.chat, mask: chatMask, detail: "当前使用")
                TextField("默认模型名", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("默认模型只影响新对话；已有对话可在右上角单独切换。图片目前使用 deepseek-flash。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("思考模式", isOn: $thinking)
                if thinking {
                    Picker("推理强度", selection: $effort) {
                        Text("低").tag("low"); Text("高").tag("high"); Text("最高").tag("max")
                    }
                }
                Text("图片经 Files API 上传，一小时后自动过期。上传失败会停止本轮，不会忽略图片继续回答。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("网页搜索与抓取") {
                Picker("搜索服务", selection: $webProvider) {
                    ForEach(WebSearchProviderChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if webProvider == WebSearchProviderChoice.deepSeek.rawValue {
                    Toggle("复用聊天 Key（默认）", isOn: $reuseChatKey)
                    credentialRow(.deepSeekWeb, mask: webMask, detail: reuseChatKey ? "已保存的独立 Key · 备用" : "当前使用 · 独立 Key")
                    LabeledContent("实际生效 Key", value: reuseChatKey ? chatMask : webMask)
                    Text(reuseChatKey ? "无需再次输入：使用当前已保存的聊天 Key。点击网页 Key 可预填同一个值并改为独立保存。" : "网页调用使用独立 Key，修改它不会影响聊天。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !reuseChatKey && webMask == "未设置" { Text("请先保存独立网页 Key，或开启复用。").font(.caption).foregroundStyle(.red) }
                } else if webProvider == WebSearchProviderChoice.brave.rawValue {
                    credentialRow(.brave, mask: braveMask, detail: "当前服务使用")
                } else {
                    Text("无需 Key。RSS 召回和抓取质量有限。").font(.caption).foregroundStyle(.secondary)
                }
                Text("用于输入框“联网搜索”和日常对话的 web_search。多轮 Deep Search 仍暂停开发，未切换其研究组件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("云端任务") {
                DisclosureGroup("服务地址与访问令牌", isExpanded: $cloudExpanded) {
                    TextField("HTTPS 服务地址", text: $cloudServiceURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    credentialRow(.cloud, mask: cloudMask, detail: "非 DeepSeek Key")
                    Button(checking ? "正在连接…" : "测试任务服务") { testCloudService() }.disabled(checking)
                    if let connectionStatus { Text(connectionStatus).font(.caption).foregroundStyle(.secondary) }
                }
                Text("仅用于定时任务、历史及推送。知识库只有明确选择并主动同步后才会上云。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("申请任务推送权限") {
                    Task {
                        let granted = await PushRegistration.shared.requestAuthorizationAndRegister()
                        notificationStatus = granted ? "通知已授权；已请求 APNs 注册，是否送达仍需真机验证。" : "未获通知权限，请在系统设置中开启。"
                    }
                }.disabled(cloudMask == "未设置")
                if let notificationStatus { Text(notificationStatus).font(.caption).foregroundStyle(.secondary) }
            }
            Section("本地记忆") {
                NavigationLink("历史对话记忆导入") { HistoricalMemoryImportView(model: memoryImport) }
                Text("记忆保存在本机；导入和提取会调用 DeepSeek。不会自动同步整个聊天库。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #if DEBUG
            Section {
                DisclosureGroup("开发诊断") {
                    NavigationLink("Memory 语义评测") { MemorySemanticEvaluationView() }
                    NavigationLink("Memory Precision 评测") { MemorySemanticPrecisionView() }
                }
            }
            #endif
            Section("关于") {
                LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                Text("凭据保存在本机 Keychain。列表默认掩码；点入可查看、编辑或删除。真实 Key 不写入工程和日志。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .sheet(item: $editing) { slot in CredentialEditor(slot: slot, onSaved: refreshKeys) }
        .onAppear {
            if !["low", "high", "max"].contains(effort) { effort = "low" }
            if userID.isEmpty { userID = "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
            refreshKeys()
        }
    }
    private func credentialRow(_ slot: CredentialSlot, mask: String, detail: String) -> some View {
        Button { editing = slot } label: {
            HStack(spacing: 12) {
                Image(systemName: "key.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(slot.title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(mask).font(.caption.monospaced()).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 3)
        }
    }
    private func refreshKeys() {
        chatMask = ClientCredentials.masked(KeychainStore.readAPIKey())
        webMask = ClientCredentials.masked(KeychainStore.readDeepSeekWebKey())
        cloudMask = ClientCredentials.masked(KeychainStore.readCloudServiceToken())
        braveMask = ClientCredentials.masked(KeychainStore.readSearchAPIKey())
    }
    private func testCloudService() {
        guard let url = URL(string: cloudServiceURL), url.scheme == "https", !userID.isEmpty else { connectionStatus = "请输入有效 HTTPS 地址"; return }
        checking = true; connectionStatus = nil
        Task {
            do { _ = try await TaskAPI(base: url, userID: userID).list(); connectionStatus = "任务服务连接成功" }
            catch { connectionStatus = error.localizedDescription }
            checking = false
        }
    }
}

private struct HistoricalMemoryImportView: View {
    @ObservedObject var model: MemoryBackfillViewModel
    var body: some View {
        Form {
            Section {
                Text("扫描仅访问本地。确认导入后，会发送完整的历史用户消息与最终回答给 DeepSeek 提取记忆，不发送思考过程或附件。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.scanning ? "正在扫描…" : "扫描历史对话") { model.scan() }.disabled(model.scanning || model.isRunning)
            }
            if let report = model.preflight {
                Section("导入预览") {
                    LabeledContent("对话", value: "\(report.conversationCount)")
                    LabeledContent("可导入轮次", value: "\(report.eligibleTurnCount)")
                    LabeledContent("已处理", value: "\(report.alreadyProcessedCount)")
                    LabeledContent("可重试失败", value: "\(report.failedRetryCount)")
                    LabeledContent("预计请求", value: "\(report.estimatedRequestCount)")
                    LabeledContent("预计输入 tokens", value: "约 \(report.estimatedInputTokens)")
                    Button("确认并开始导入") { model.start() }.disabled(model.isRunning || report.estimatedRequestCount == 0)
                }
            }
            if model.progress.state != .idle {
                Section("进度") {
                    ProgressView(value: Double(model.progress.processed), total: Double(max(1, model.progress.processed + model.progress.remaining)))
                    Text("已处理 \(model.progress.processed) · 成功 \(model.progress.succeeded) · 无需记忆 \(model.progress.noop) · 失败 \(model.progress.failed) · 剩余 \(model.progress.remaining)").font(.caption)
                    if model.isRunning { Button("取消导入", role: .destructive) { model.cancel() } }
                    else { Text(model.statusText) }
                }
            }
            if let error = model.errorText { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle("历史记忆导入").navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
final class MemoryBackfillViewModel: ObservableObject {
    @Published var preflight: MemoryBackfillPreflight?
    @Published var progress = MemoryBackfillProgress()
    @Published var scanning = false
    @Published var errorText: String?
    private let memoryService: MemoryService

    init(memoryService: MemoryService) {
        self.memoryService = memoryService
    }

    var isRunning: Bool { progress.state == .running }
    var statusText: String {
        switch progress.state {
        case .completed: "导入完成"
        case .cancelled: "已取消；已成功导入的内容会保留，可重新扫描后继续"
        case .partiallyFailed: "部分失败，可重新运行继续"
        case .idle, .running: ""
        }
    }

    func scan() {
        scanning = true
        errorText = nil
        Task {
            do { preflight = try await memoryService.historicalMemoryPreflight() }
            catch { errorText = error.localizedDescription }
            scanning = false
        }
    }

    func start() {
        errorText = nil
        progress.state = .running
        Task {
            progress = await memoryService.startHistoricalMemoryImport { [weak self] update in
                Task { @MainActor in self?.progress = update }
            }
            scan()
        }
    }

    func cancel() {
        Task { await memoryService.cancelHistoricalMemoryImport() }
    }
}
