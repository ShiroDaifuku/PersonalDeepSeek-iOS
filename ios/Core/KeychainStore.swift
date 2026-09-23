import Foundation
import Security

enum KeychainStore {
    private static let service = "local.personal.deepseek"
    private static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil); guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func delete(account: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary) }
    static func saveAPIKey(_ value: String) throws { try save(value, account: "deepseek-api-key") }
    static func readAPIKey() -> String? { read(account: "deepseek-api-key") }
    static func deleteAPIKey() { delete(account: "deepseek-api-key") }
    static func saveProxyToken(_ value: String) throws { try save(value, account: "proxy-access-token") }
    static func readProxyToken() -> String? { read(account: "proxy-access-token") }
    static func deleteProxyToken() { delete(account: "proxy-access-token") }
}
