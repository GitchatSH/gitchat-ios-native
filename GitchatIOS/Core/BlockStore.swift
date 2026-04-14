import Foundation

/// Local block list — stored in UserDefaults. Hides messages from blocked
/// users from the UI. Apple's UGC moderation requirements are satisfied by
/// a client-side block list as long as the block happens immediately and
/// persists across sessions.
@MainActor
final class BlockStore: ObservableObject {
    static let shared = BlockStore()

    @Published private(set) var blockedLogins: Set<String> = []

    private let key = "gitchat.blocked_logins.v1"

    private init() {
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] {
            blockedLogins = Set(arr)
        }
    }

    func isBlocked(_ login: String) -> Bool {
        blockedLogins.contains(login)
    }

    func block(_ login: String) {
        blockedLogins.insert(login)
        persist()
    }

    func unblock(_ login: String) {
        blockedLogins.remove(login)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(blockedLogins), forKey: key)
    }
}
