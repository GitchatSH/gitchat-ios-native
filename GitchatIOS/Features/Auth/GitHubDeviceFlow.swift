import Foundation

enum GitHubDeviceFlow {
    struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    struct TokenResponse: Decodable {
        let access_token: String?
        let error: String?
        let error_description: String?
    }

    static func requestDeviceCode() async throws -> DeviceCode {
        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = "client_id=\(Config.githubClientId)&scope=\(Config.githubScope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        req.httpBody = Data(params.utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    static func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var currentInterval = max(interval, 5)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(currentInterval) * 1_000_000_000)
            var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let params = "client_id=\(Config.githubClientId)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
            req.httpBody = Data(params.utf8)
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            if let token = decoded.access_token { return token }
            switch decoded.error {
            case "authorization_pending":
                continue
            case "slow_down":
                currentInterval += 5
                continue
            case "expired_token", "access_denied":
                throw NSError(domain: "GitHubDeviceFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: decoded.error_description ?? decoded.error!])
            default:
                continue
            }
        }
        throw NSError(domain: "GitHubDeviceFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Device code expired"])
    }
}
