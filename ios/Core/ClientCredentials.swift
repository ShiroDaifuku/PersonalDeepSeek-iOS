import Foundation

enum WebSearchProviderChoice: String, CaseIterable, Identifiable, Sendable {
    case deepSeek, bing, brave
    var id: String { rawValue }
    var title: String {
        switch self { case .deepSeek: "DeepSeek 官方"; case .bing: "Bing RSS（免 Key）"; case .brave: "Brave（可回退 Bing）" }
    }
}

enum ClientCredentials {
    static let webProviderSetting = "interactiveWebProvider"
    static let reuseChatKeySetting = "deepSeekWebUsesChatKey"

    static func webProvider(defaults: UserDefaults = .standard) -> WebSearchProviderChoice {
        WebSearchProviderChoice(rawValue: defaults.string(forKey: webProviderSetting) ?? "") ?? .deepSeek
    }
    static func reusesChatKey(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: reuseChatKeySetting) == nil || defaults.bool(forKey: reuseChatKeySetting)
    }
    static func resolvedWebKey() -> String? {
        reusesChatKey() ? KeychainStore.readAPIKey() : KeychainStore.readDeepSeekWebKey()
    }
    static func validated(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw CredentialError.invalid
        }
        return value
    }
    static func masked(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "未设置" }
        guard value.count >= 12 else { return "已保存 · ••••••••" }
        return "\(value.prefix(3))••••••••\(value.suffix(4))"
    }
    enum CredentialError: LocalizedError {
        case invalid
        var errorDescription: String? { "请输入有效的 Key 或令牌，不能含空格或换行。" }
    }
}
