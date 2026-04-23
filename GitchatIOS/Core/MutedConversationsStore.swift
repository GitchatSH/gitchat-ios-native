import Foundation

/// Shared between the main app and the OneSignal NSE via app-group
/// UserDefaults. Main app writes the current set of muted conversation
/// ids; NSE reads it to silence incoming pushes on the lockscreen.
enum MutedConversationsStore {
    private static let appGroup = "group.chat.git.onesignal"
    private static let key = "gitchat.muted_conversation_ids"

    static var current: Set<String> {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let arr = defaults.array(forKey: key) as? [String] else {
            return []
        }
        return Set(arr)
    }

    static func contains(_ id: String) -> Bool {
        current.contains(id)
    }

    static func replace(with ids: Set<String>) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(Array(ids), forKey: key)
    }

    static func insert(_ id: String) {
        var set = current
        set.insert(id)
        replace(with: set)
    }

    static func remove(_ id: String) {
        var set = current
        set.remove(id)
        replace(with: set)
    }
}
