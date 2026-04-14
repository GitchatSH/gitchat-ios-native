import Foundation
import Security

@MainActor
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    @Published private(set) var login: String?
    @Published private(set) var accessToken: String?
    @Published var isAuthenticated: Bool = false

    private let service = "chat.git.gitchat"
    private let tokenKey = "access_token"
    private let loginKey = "login"

    private init() {
        self.accessToken = read(tokenKey)
        self.login = read(loginKey)
        self.isAuthenticated = accessToken != nil
    }

    func save(token: String, login: String) {
        write(tokenKey, value: token)
        write(loginKey, value: login)
        self.accessToken = token
        self.login = login
        self.isAuthenticated = true
    }

    func signOut() {
        delete(tokenKey)
        delete(loginKey)
        self.accessToken = nil
        self.login = nil
        self.isAuthenticated = false
    }

    // MARK: - Keychain

    private func write(_ key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
