import SwiftUI

struct SettingsView: View {
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
                Text("仅定时任务、执行历史和推送使用该服务；不上传本地资料库。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本地联网研究") {
                SecureField("Brave Search API Key", text: $searchKey).textContentType(.password)
                Button("保存搜索 Key") { do { try KeychainStore.saveSearchAPIKey(searchKey); searchKey = ""; saved = true } catch { saved = false } }
                Button("删除搜索 Key", role: .destructive) { KeychainStore.deleteSearchAPIKey() }
                Text("搜索与网页抓取由本机发起；Key 只保存在 Keychain，研究结果不会上传到云端任务服务。")
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
            Section("说明") { Text("App 会自动路由：交互功能在本机执行，必须在手机离线时运行的任务交给云端。不需要切换连接模式。") }
            Section("版本") {
                LabeledContent("客户端", value: "0.4.0 (13)")
                LabeledContent("工具路由", value: "v2 · 明确意图强制调用")
            }
        }.navigationTitle("设置").onAppear { if userID.isEmpty { userID = "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } }
    }
    private func testCloudService() {
        guard let url = URL(string: cloudServiceURL), url.scheme == "https", !userID.isEmpty else { connectionStatus = "请输入有效的 HTTPS 服务地址"; return }
        checking = true; connectionStatus = nil
        Task { do { _ = try await TaskAPI(base: url, userID: userID).list(); connectionStatus = "连接成功" } catch { connectionStatus = error.localizedDescription }; checking = false }
    }
}
