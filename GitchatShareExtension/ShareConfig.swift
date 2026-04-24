import Foundation

enum ShareConfig {
    static let appGroup = "group.chat.git.share"
    static let tokenKey = "shared_access_token"
    static let loginKey = "shared_login"
    static let userAgent = "gitchat-ios-share/1.0.4"

    /// Same override story as `Config.apiBaseURL` (see there), but
    /// scoped to the share extension. Launch arguments don't apply —
    /// the extension isn't launched with user-set args — so only env
    /// var and app-group UserDefaults are consulted. Using the same
    /// app-group suite as the main app means a debug URL written once
    /// from the host app propagates here automatically.
    ///
    /// `#if DEBUG`-gated so Release builds always hit the canonical
    /// API. `static let` caches after first access; relaunch the
    /// extension (share again) to apply a changed override.
    static let apiBaseURL: URL = {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["API_BASE_URL"],
           let url = URL(string: value) {
            return url
        }
        if let defaults = UserDefaults(suiteName: appGroup),
           let value = defaults.string(forKey: "debug.apiBaseURL"),
           let url = URL(string: value) {
            return url
        }
        #endif
        return URL(string: "https://api-dev.gitchat.sh/api/v1")!
    }()
}
