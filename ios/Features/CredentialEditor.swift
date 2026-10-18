import SwiftUI

enum CredentialSlot: String, Identifiable, CaseIterable {
    case chat, deepSeekWeb, cloud, brave
    var id: String { rawValue }
    var title: String {
        switch self { case .chat: "聊天与图片 Key"; case .deepSeekWeb: "DeepSeek 网页 Key"; case .cloud: "云端任务访问令牌"; case .brave: "Brave 搜索 Key" }
    }
    var help: String {
        switch self {
        case .chat: "用于聊天、图片上传与识别，以及现有长期记忆功能。仅存入本机 Keychain。"
        case .deepSeekWeb: "仅用于 DeepSeek 官方 Search / Fetch。保存后将独立使用此 Key，不修改聊天 Key。"
        case .cloud: "这是你自己的云端任务服务令牌，不是 DeepSeek API Key。"
        case .brave: "只在选择 Brave 搜索时使用，不会发给 DeepSeek。"
        }
    }
    func read() -> String? {
        switch self { case .chat: KeychainStore.readAPIKey(); case .deepSeekWeb: KeychainStore.readDeepSeekWebKey(); case .cloud: KeychainStore.readCloudServiceToken(); case .brave: KeychainStore.readSearchAPIKey() }
    }
    func save(_ value: String) throws {
        switch self {
        case .chat: try KeychainStore.saveAPIKey(value)
        case .deepSeekWeb:
            try KeychainStore.saveDeepSeekWebKey(value)
            UserDefaults.standard.set(false, forKey: ClientCredentials.reuseChatKeySetting)
        case .cloud: try KeychainStore.saveCloudServiceToken(value)
        case .brave: try KeychainStore.saveSearchAPIKey(value)
        }
    }
    func delete() {
        switch self { case .chat: KeychainStore.deleteAPIKey(); case .deepSeekWeb: KeychainStore.deleteDeepSeekWebKey(); case .cloud: KeychainStore.deleteCloudServiceToken(); case .brave: KeychainStore.deleteSearchAPIKey() }
    }
}

struct CredentialEditor: View {
    let slot: CredentialSlot
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var visible = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var hasStoredValue = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Group {
                            if visible { TextField("输入 Key 或令牌", text: $value) }
                            else { SecureField("输入 Key 或令牌", text: $value) }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        Button { visible.toggle() } label: { Image(systemName: visible ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless).accessibilityLabel(visible ? "隐藏密钥" : "显示密钥")
                    }
                    if hasStoredValue { Label("正在编辑已保存的值", systemImage: "lock.shield") }
                    if slot == .deepSeekWeb && !hasStoredValue && !value.isEmpty {
                        Text("已预填当前聊天 Key；保存后可单独编辑和使用。").font(.caption).foregroundStyle(.secondary)
                    }
                } footer: { Text(slot.help) }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if hasStoredValue {
                    Section { Button("删除此凭据", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(slot.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try slot.save(ClientCredentials.validated(value)); value = ""; visible = false; onSaved(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                let stored = slot.read(); hasStoredValue = stored?.isEmpty == false
                value = stored ?? (slot == .deepSeekWeb ? (KeychainStore.readAPIKey() ?? "") : "")
            }
            .onDisappear { value = ""; visible = false }
            .alert("删除\(slot.title)？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) { slot.delete(); onSaved(); dismiss() }
                Button("取消", role: .cancel) { }
            } message: { Text(slot == .deepSeekWeb ? "仅删除本机凭据，不撤销服务端 Key。删除后可开启复用聊天 Key。" : "仅删除本机凭据，不会撤销服务端 Key 或令牌。下一次调用需要重新配置。") }
        }
    }
}
