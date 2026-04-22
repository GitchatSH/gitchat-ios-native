import Foundation

enum ShareConfig {
    static let apiBaseURL = URL(string: "https://api-dev.gitchat.sh/api/v1")!
    static let appGroup = "group.chat.git.share"
    static let tokenKey = "shared_access_token"
    static let loginKey = "shared_login"
    static let userAgent = "gitchat-ios-share/1.0.4"
}
