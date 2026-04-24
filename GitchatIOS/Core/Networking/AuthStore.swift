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

    // Share extension reads from this App Group so tapping
    // "Share → Gitchat" can call the API with the user's token.
    private let sharedGroup = "group.chat.git.share"
    private let sharedTokenKey = "shared_access_token"
    private let sharedLoginKey = "shared_login"

    private init() {
        self.accessToken = read(tokenKey)
        self.login = read(loginKey)
        self.isAuthenticated = accessToken != nil
        self.needsGithubLink = read(needsGithubKey) == "1"
        mirrorToSharedGroup()
    }

    func save(token: String, login: String, needsGithubLink: Bool = false, method: String = "unknown") {
        let isNewUser = read(loginKey) == nil
        write(tokenKey, value: token)
        write(loginKey, value: login)
        write(needsGithubKey, value: needsGithubLink ? "1" : "0")
        self.accessToken = token
        self.login = login
        self.needsGithubLink = needsGithubLink
        self.isAuthenticated = true
        mirrorToSharedGroup()
        PushManager.shared.identify(login: login)
        AnalyticsTracker.setUserID(login)
        if isNewUser {
            AnalyticsTracker.trackSignUp(method: method)
        } else {
            AnalyticsTracker.trackLogin(method: method)
        }
        Task {
            await PushManager.shared.requestPermission()
            // Once permission is resolved, sync whatever subscription
            // OneSignal has to BE. If the SDK hasn't produced an id
            // yet, the OSPushSubscriptionObserver fire will cover it
            // later — this call is just the eager path.
            await PushSubscriptionSync.shared.syncCurrent()
        }
    }

    func clearNeedsGithubLink() {
        write(needsGithubKey, value: "0")
        self.needsGithubLink = false
    }

    func signOut() {
        // Unregister the push subscription BEFORE clearing the auth
        // token — the DELETE endpoint needs the Bearer header to
        // authenticate the owner. After tokenKey is wiped the call
        // would 401.
        Task { await PushSubscriptionSync.shared.onSignOut() }
        delete(tokenKey)
        delete(loginKey)
        delete(needsGithubKey)
        self.accessToken = nil
        self.login = nil
        self.needsGithubLink = false
        self.isAuthenticated = false
        clearSharedGroup()
        AnalyticsTracker.clearUserID()
        PushManager.shared.forgetIdentity()
    }

    private func mirrorToSharedGroup() {
        guard let shared = UserDefaults(suiteName: sharedGroup) else { return }
        shared.set(accessToken, forKey: sharedTokenKey)
        shared.set(login, forKey: sharedLoginKey)
    }

    private func clearSharedGroup() {
        guard let shared = UserDefaults(suiteName: sharedGroup) else { return }
        shared.removeObject(forKey: sharedTokenKey)
        shared.removeObject(forKey: sharedLoginKey)
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
