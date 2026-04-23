import Foundation

enum Config {
    static let apiBaseURL = URL(string: "https://api-dev.gitchat.sh/api/v1")!
    static let wsURL = URL(string: "https://ws-dev.gitchat.sh")!
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
