import Foundation

enum Config {
    // Default endpoints. Override locally without committing by either:
    //   1. Xcode scheme env vars API_BASE_URL / WS_URL (user scheme under
    //      xcuserdata/ is gitignored).
    //   2. Launch arguments -debug.apiBaseURL <url> / -debug.wsURL <url>
    //      (useful for overriding at runtime without restarting Xcode).
    //   3. UserDefaults keys "debug.apiBaseURL" / "debug.wsURL" (can be set
    //      from a debug screen inside the app, survives relaunches).
    // Precedence: launch args > env var > UserDefaults > default.
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

    private static func resolveURL(
        envKey: String,
        argKey: String,
        defaultsKey: String,
        fallback: String
    ) -> URL {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: argKey), idx + 1 < args.count,
           let url = URL(string: args[idx + 1]) {
            return url
        }
        if let value = ProcessInfo.processInfo.environment[envKey],
           let url = URL(string: value) {
            return url
        }
        if let value = UserDefaults.standard.string(forKey: defaultsKey),
           let url = URL(string: value) {
            return url
        }
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
