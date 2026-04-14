import Foundation

enum Config {
    static let apiBaseURL = URL(string: "https://api-dev.gitstar.ai/api/v1")!
    static let wsURL = URL(string: "https://ws-dev.gitstar.ai")!
    static let githubClientId = "Ov23liXf7KFWwKzcOHE0"
    static let githubScope = "read:user user:follow"
    static let presenceHeartbeatSeconds: TimeInterval = 60
    static let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()
    static let userAgent = "gitchat-ios/\(appVersion)"
}
