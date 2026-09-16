import Foundation
import Security

/// Read-and-delete access to the Keychain item that versions 1.0–1.1 used
/// for the API key. Kept only for the one-time migration back into
/// UserDefaults (see `SettingsStore.migrateAPIKeyFromKeychain`); nothing
/// writes here anymore.
enum Keychain {
    private static let service = "com.babelbar.app"
    private static let account = "soniox-api-key"

    static func loadAPIKey() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return "" }
        return key
    }

    static func deleteAPIKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
