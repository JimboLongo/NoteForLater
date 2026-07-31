import Foundation
import Security

struct StoredGoogleTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var email: String
    var displayName: String
}

/// Minimal Keychain wrapper for the one thing we store: the signed-in
/// Google account's OAuth tokens. Deliberately not UserDefaults — these are
/// credentials, not preferences.
enum KeychainTokenStore {
    private static let service = "com.jimbo.NoteForLater.google"
    private static let account = "google-oauth-tokens"

    static func save(_ tokens: StoredGoogleTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load() -> StoredGoogleTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredGoogleTokens.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
