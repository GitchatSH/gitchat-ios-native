import Foundation
import Security

@MainActor
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    @Published private(set) var login: String?
    @Published private(set) var accessToken: String?
    @Published var isAuthenticated: Bool = false
    @Published var needsGithubLink: Bool = false

    private let service = "chat.git.gitchat"
    private let tokenKey = "access_token"
    private let loginKey = "login"
    private let needsGithubKey = "needs_github_link"

    private init() {
        self.accessToken = read(tokenKey)
        self.login = read(loginKey)
        self.isAuthenticated = accessToken != nil
        self.needsGithubLink = read(needsGithubKey) == "1"
    }

    func save(token: String, login: String, needsGithubLink: Bool = false) {
        write(tokenKey, value: token)
        write(loginKey, value: login)
        write(needsGithubKey, value: needsGithubLink ? "1" : "0")
        self.accessToken = token
        self.login = login
        self.needsGithubLink = needsGithubLink
        self.isAuthenticated = true
    }

    func clearNeedsGithubLink() {
        write(needsGithubKey, value: "0")
        self.needsGithubLink = false
    }

    func signOut() {
        delete(tokenKey)
        delete(loginKey)
        delete(needsGithubKey)
        self.accessToken = nil
        self.login = nil
        self.needsGithubLink = false
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
