import SwiftUI

struct SettingsView: View {
    @AppStorage("connectionMode") private var mode = ConnectionMode.proxy.rawValue
    @AppStorage("proxyURL") private var proxyURL = "http://127.0.0.1:8787/"
    @AppStorage("defaultModel") private var model = "deepseek-flash"
    @AppStorage("thinkingEnabled") private var thinking = true
    @AppStorage("reasoningEffort") private var effort = "high"
    @AppStorage("opaqueUserID") private var userID = ""
    @State private var key = ""
    @State private var proxyToken = ""
    @State private var saved = false
    @State private var connectionStatus: String?
    @State private var checking = false
    @State private var notificationStatus: String?
    var body: some View {
        Form {
            Section("连接") {
                Picker("模式", selection: $mode) { Text("后端代理").tag(ConnectionMode.proxy.rawValue); Text("自备 Key 直连").tag(ConnectionMode.direct.rawValue) }
                if mode == ConnectionMode.proxy.rawValue {
                    TextField("代理地址", text: $proxyURL).textInputAutocapitalization(.never).keyboardType(.URL)
                    SecureField("访问令牌", text: $proxyToken).textContentType(.password)
                    Button("保存访问令牌") { do { try KeychainStore.saveProxyToken(proxyToken); proxyToken = ""; saved = true } catch { saved = false } }
                    Button("删除访问令牌", role: .destructive) { KeychainStore.deleteProxyToken() }
                    Button(checking ? "正在测试…" : "测试代理连接") { testProxy() }.disabled(checking)
                    if let connectionStatus { Text(connectionStatus).font(.caption).foregroundStyle(connectionStatus == "连接成功" ? .green : .red) }
                }
                else {
                    SecureField("DeepSeek API Key", text: $key).textContentType(.password)
                    Button("保存到 Keychain") { do { try KeychainStore.saveAPIKey(key); key = ""; saved = true } catch { saved = false } }
                    Button("删除 Key", role: .destructive) { KeychainStore.deleteAPIKey() }
                    if saved { Text("已安全保存").foregroundStyle(.green) }
                }
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
            Section("说明") { Text("直连模式的 Key 只存入系统 Keychain，不会写入 SwiftData、UserDefaults 或日志。任务功能始终需要本地后端。") }
        }.navigationTitle("设置").onAppear { if userID.isEmpty { userID = "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } }
    }
    private func testProxy() {
        guard let url = URL(string: proxyURL), !userID.isEmpty else { connectionStatus = "代理地址无效"; return }
        checking = true; connectionStatus = nil
        Task { do { _ = try await TaskAPI(base: url, userID: userID).list(); connectionStatus = "连接成功" } catch { connectionStatus = error.localizedDescription }; checking = false }
    }
}
