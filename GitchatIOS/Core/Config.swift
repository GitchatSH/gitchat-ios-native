import Foundation

enum Config {
    // Default endpoints. In DEBUG builds only, these can be overridden
    // locally without committing config changes by either:
    //   1. Xcode scheme env vars API_BASE_URL / WS_URL (user scheme
    //      under xcuserdata/ is gitignored).
    //   2. Launch arguments -debug.apiBaseURL <url> / -debug.wsURL <url>
    //      (override without restarting Xcode — edit scheme args).
    //   3. App-group UserDefaults keys "debug.apiBaseURL" /
    //      "debug.wsURL" (can be set from a debug screen inside the
    //      app and survives relaunches; shared via
    //      `group.chat.git.share` so the share extension picks up the
    //      same override).
    // Precedence: launch args > env var > UserDefaults > default.
    //
    // Override paths are `#if DEBUG`-gated so Release / TestFlight /
    // App Store builds can never be pointed at an attacker-supplied
    // URL via a written UserDefaults key. Defaults are unchanged for
    // all users.
    static let apiBaseURL = resolveURL(
        envKey: "API_BASE_URL",
        argKey: "-debug.apiBaseURL",
        defaultsKey: "debug.apiBaseURL",
        fallback: "https://api-dev.gitchat.sh/api/v1"
    )
    static let wsURL = resolveURL(
        envKey: "WS_URL",
        argKey: "-debug.wsURL",
        defaultsKey: "debug.wsURL",
        fallback: "https://ws-dev.gitchat.sh"
    )

    /// Shared with the share extension so a single debug override
    /// reaches both processes. Must match `ShareConfig.appGroup`.
    private static let appGroupSuite = "group.chat.git.share"

    /// `static let` caches the resolved URL after first access — the
    /// override sources are read once per app launch. Restart the
    /// app (or toggle the launch arg) to apply a changed override.
    private static func resolveURL(
        envKey: String,
        argKey: String,
        defaultsKey: String,
        fallback: String
    ) -> URL {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: argKey), idx + 1 < args.count,
           let url = URL(string: args[idx + 1]) {
            return url
        }
        if let value = ProcessInfo.processInfo.environment[envKey],
           let url = URL(string: value) {
            return url
        }
        if let defaults = UserDefaults(suiteName: appGroupSuite),
           let value = defaults.string(forKey: defaultsKey),
           let url = URL(string: value) {
            return url
        }
        #endif
        return URL(string: fallback)!
    }
    static let githubClientId = "Ov23lin5OyRE9J7Rvsrv"
    static let githubScope = "read:user user:follow"
    // 30s matches the backend's Redis TTL budget (90s online key TTL,
    // 75s sweeper cutoff). Raising this past ~45s risks flickering offline.
    static let presenceHeartbeatSeconds: TimeInterval = 30
    static let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()
    static let userAgent = "gitchat-ios/\(appVersion)"

    // Legal documents (hosted at gitchat-legal.vercel.app)
    static let legalBase = URL(string: "https://gitchat-legal.vercel.app")!
    static let eulaURL = legalBase.appendingPathComponent("eula.html")
    static let termsURL = legalBase.appendingPathComponent("terms.html")
    static let privacyURL = legalBase.appendingPathComponent("privacy.html")
}
