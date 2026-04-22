import Foundation

enum ShareTokenStore {
    static func token() -> String? {
        UserDefaults(suiteName: ShareConfig.appGroup)?.string(forKey: ShareConfig.tokenKey)
    }

    static func login() -> String? {
        UserDefaults(suiteName: ShareConfig.appGroup)?.string(forKey: ShareConfig.loginKey)
    }
}
