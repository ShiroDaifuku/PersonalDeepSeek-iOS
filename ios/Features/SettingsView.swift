import SwiftUI

struct SettingsView: View {
    @StateObject private var memoryImport: MemoryBackfillViewModel
    @AppStorage("cloudServiceURL") private var cloudServiceURL = CloudServiceDefaults.baseURL
    @AppStorage("defaultModel") private var model = "deepseek-flash"
    @AppStorage("thinkingEnabled") private var thinking = true
    @AppStorage("reasoningEffort") private var effort = "high"
    @AppStorage("opaqueUserID") private var userID = ""
    @State private var key = ""
    @State private var searchKey = ""
    @State private var proxyToken = ""
    @State private var saved = false
    @State private var connectionStatus: String?
    @State private var checking = false
    @State private var notificationStatus: String?

    init(memoryService: MemoryService) {
        _memoryImport = StateObject(wrappedValue: MemoryBackfillViewModel(memoryService: memoryService))
    }

    var body: some View {
        Form {
            Section("DeepSeek") {
                SecureField("DeepSeek API Key", text: $key).textContentType(.password)
                Button("保存到 Keychain") { do { try KeychainStore.saveAPIKey(key); key = ""; saved = true } catch { saved = false } }
                Button("删除 Key", role: .destructive) { KeychainStore.deleteAPIKey() }
                if saved { Text("已安全保存").foregroundStyle(.green) }
                Text("聊天、图片分析、资料库检索和用户主动发起的研究直接在本机编排。Key 只保存在系统 Keychain。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("云端任务服务") {
                TextField("https://你的服务地址/", text: $cloudServiceURL).textInputAutocapitalization(.never).keyboardType(.URL)
                SecureField("服务访问令牌", text: $proxyToken).textContentType(.password)
                Button("保存服务令牌") { do { try KeychainStore.saveCloudServiceToken(proxyToken); proxyToken = ""; saved = true } catch { saved = false } }
                Button("删除服务令牌", role: .destructive) { KeychainStore.deleteCloudServiceToken() }
                Button(checking ? "正在测试…" : "测试云端任务服务") { testCloudService() }.disabled(checking)
                if let connectionStatus { Text(connectionStatus).font(.caption).foregroundStyle(connectionStatus == "连接成功" ? .green : .red) }
                Text("定时任务、执行历史和推送使用该服务。知识库默认不上传；只有你在资料库页逐个开启并主动同步的内容，才可供云端任务检索。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本地联网研究") {
                SecureField("Brave Search API Key（可选）", text: $searchKey).textContentType(.password)
                Button("保存搜索 Key") { do { try KeychainStore.saveSearchAPIKey(searchKey); searchKey = ""; saved = true } catch { saved = false } }
                Button("删除搜索 Key", role: .destructive) { KeychainStore.deleteSearchAPIKey() }
                Text("搜索与网页抓取由本机发起。未配置 Key 时自动使用免密搜索回退；配置 Brave Key 后优先使用 Brave，Key 只保存在 Keychain。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("模型") {
                TextField("模型名", text: $model).textInputAutocapitalization(.never)
                Toggle("思考模式", isOn: $thinking)
                Picker("推理强度", selection: $effort) { ForEach(["none", "low", "high", "max"], id: \.self, content: Text.init) }
            }
            Section("系统集成") {
                Button("启用任务推送") {
                    Task { let granted = await PushRegistration.shared.requestAuthorizationAndRegister(); notificationStatus = granted ? "通知已授权；正在向 APNs 注册设备" : "通知权限未授予，请在系统设置中开启" }
                }
                if let notificationStatus { Text(notificationStatus).font(.caption).foregroundStyle(.secondary) }
                Text("小组件和 Live Activity 使用 App Group 共享快照；扩展不会自行联网。").font(.caption).foregroundStyle(.secondary)
            }
            Section("历史长期记忆导入") {
                Text("扫描只读取本地数据，不会调用 DeepSeek。开始导入后，会把符合条件的历史用户消息与最终回答发送给当前配置的 DeepSeek API，用于提取长期记忆。不会发送思考过程、附件、图片或文件内容；已处理的轮次会自动跳过。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(memoryImport.scanning ? "正在扫描…" : "扫描历史对话") {
                    memoryImport.scan()
                }
                .disabled(memoryImport.scanning || memoryImport.isRunning)
                if let report = memoryImport.preflight {
                    LabeledContent("历史对话", value: "\(report.conversationCount)")
                    LabeledContent("可导入轮次", value: "\(report.eligibleTurnCount)")
                    LabeledContent("已处理", value: "\(report.alreadyProcessedCount)")
                    LabeledContent("可重试失败", value: "\(report.failedRetryCount)")
                    LabeledContent("预计 API 请求", value: "\(report.estimatedRequestCount)")
                    LabeledContent("预计输入 Token", value: "约 \(report.estimatedInputTokens)")
                    if let earliest = report.earliestTurnDate, let latest = report.latestTurnDate {
                        LabeledContent("时间范围") {
                            Text("\(earliest.formatted(date: .abbreviated, time: .omitted)) – \(latest.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                    Button("确认并开始导入") { memoryImport.start() }
                        .disabled(memoryImport.isRunning || report.estimatedRequestCount == 0)
                }
                if memoryImport.progress.state != .idle {
                    ProgressView(
                        value: Double(memoryImport.progress.processed),
                        total: Double(max(1, memoryImport.progress.processed + memoryImport.progress.remaining))
                    )
                    Text("已处理 \(memoryImport.progress.processed)，成功 \(memoryImport.progress.succeeded)，无需记忆 \(memoryImport.progress.noop)，失败 \(memoryImport.progress.failed)，剩余 \(memoryImport.progress.remaining)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if memoryImport.isRunning {
                        Button("取消导入", role: .destructive) { memoryImport.cancel() }
                    } else {
                        Text(memoryImport.statusText).font(.caption)
                    }
                }
                if let error = memoryImport.errorText {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("说明") { Text("App 会自动路由：交互功能在本机执行，必须在手机离线时运行的任务交给云端。不需要切换连接模式。") }
            #if DEBUG
            Section("开发者") {
                NavigationLink("Memory 真机语义评测") { MemorySemanticEvaluationView() }
                NavigationLink("Memory Semantic Precision 调优") { MemorySemanticPrecisionView() }
                Text("只在 DEBUG 构建显示；不会读取或修改真实 Memory。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
            Section("版本") {
                LabeledContent("客户端", value: "0.5.0 (14)")
                LabeledContent("工具路由", value: "v3 · 知识库管理与动态任务检索")
            }
        }.navigationTitle("设置").onAppear { if userID.isEmpty { userID = "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } }
    }
    private func testCloudService() {
        guard let url = URL(string: cloudServiceURL), url.scheme == "https", !userID.isEmpty else { connectionStatus = "请输入有效的 HTTPS 服务地址"; return }
        checking = true; connectionStatus = nil
        Task { do { _ = try await TaskAPI(base: url, userID: userID).list(); connectionStatus = "连接成功" } catch { connectionStatus = error.localizedDescription }; checking = false }
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
