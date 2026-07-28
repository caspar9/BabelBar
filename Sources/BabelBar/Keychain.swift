import Foundation
import Security

/// Minimal Keychain wrapper for the STT API key.
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

    static func saveAPIKey(_ key: String) {
        if key.isEmpty {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
