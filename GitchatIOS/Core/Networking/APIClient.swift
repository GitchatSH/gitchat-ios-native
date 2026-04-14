import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case notAuthenticated
    case http(Int, String?)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .notAuthenticated: return "Not signed in"
        case .http(let code, let msg): return "HTTP \(code)\(msg.map { ": \($0)" } ?? "")"
        case .decoding(let e): return "Decoding error: \(e.localizedDescription)"
        case .transport(let e): return e.localizedDescription
        }
    }
}

struct APIClient {
    static let shared = APIClient()

    let session: URLSession
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpAdditionalHeaders = [
            "User-Agent": Config.userAgent,
            "Accept": "application/json"
        ]
        self.session = URLSession(configuration: cfg)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Core request

    @discardableResult
    func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Encodable? = nil,
        requireAuth: Bool = true,
        decode: T.Type = T.self
    ) async throws -> T {
        var comps = URLComponents(url: Config.apiBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        if requireAuth {
            guard let token = await AuthStore.shared.accessToken else { throw APIError.notAuthenticated }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(AnyEncodable(body))
        }

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1, nil) }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)
            throw APIError.http(http.statusCode, text)
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        do {
            // Try envelope first
            if let wrapped = try? decoder.decode(APIEnvelope<T>.self, from: data), let inner = wrapped.data {
                return inner
            }
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    // MARK: - Feature endpoints

    // Auth
    func linkGithub(githubToken: String) async throws -> AuthLinkResponse {
        let body = AuthLinkRequest(
            github_token: githubToken,
            client_id: "gitchat-ios@\(Config.appVersion)",
            ide: "ios",
            ide_version: UIDeviceVersion.current
        )
        return try await request("auth/github-link", method: "POST", body: body, requireAuth: false)
    }

    // Conversations
    func listConversations(cursor: String? = nil, limit: Int = 30) async throws -> ConversationListResponse {
        var q = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await request("messages/conversations", query: q)
    }

    func getConversationMessages(id: String, cursor: String? = nil, limit: Int = 30) async throws -> MessagesResponse {
        var q = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await request("messages/conversations/\(id)", query: q)
    }

    func sendMessage(conversationId: String, body: String, replyTo: String? = nil) async throws -> Message {
        let req = SendMessageRequest(body: body, reply_to_id: replyTo)
        return try await request("messages/conversations/\(conversationId)", method: "POST", body: req)
    }

    func createConversation(recipient: String) async throws -> Conversation {
        let req = CreateConversationRequest(recipient_login: recipient, recipient_logins: nil, group_name: nil)
        return try await request("messages/conversations", method: "POST", body: req)
    }

    func markRead(conversationId: String) async throws {
        let _: EmptyResponse = try await request("messages/conversations/\(conversationId)/read", method: "PATCH")
    }

    func react(messageId: String, emoji: String, add: Bool) async throws {
        struct Body: Encodable { let emoji: String; let message_id: String }
        let _: EmptyResponse = try await request(
            "messages/reactions",
            method: add ? "POST" : "DELETE",
            body: Body(emoji: emoji, message_id: messageId)
        )
    }

    // Profile
    func myProfile() async throws -> UserProfile {
        try await request("user/profile")
    }

    func userProfile(login: String) async throws -> UserProfile {
        try await request("user/\(login)")
    }

    // Following
    func follow(login: String) async throws {
        let _: EmptyResponse = try await request("follow/\(login)", method: "PUT")
    }
    func unfollow(login: String) async throws {
        let _: EmptyResponse = try await request("follow/\(login)", method: "DELETE")
    }
    func followingList() async throws -> [UserProfile] {
        struct Wrap: Decodable { let users: [UserProfile] }
        let w: Wrap = try await request("following", query: [URLQueryItem(name: "per_page", value: "100")])
        return w.users
    }

    // Notifications
    func notifications(cursor: String? = nil) async throws -> NotificationListResponse {
        var q = [URLQueryItem(name: "limit", value: "30")]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await request("notifications", query: q)
    }
    func markNotificationsRead(all: Bool = true) async throws {
        struct Body: Encodable { let all: Bool }
        let _: EmptyResponse = try await request("notifications/read", method: "PATCH", body: Body(all: all))
    }

    // Channels
    func channels() async throws -> ChannelListResponse {
        try await request("channels")
    }

    // Presence
    func heartbeat() async throws {
        let _: EmptyResponse = try await request("presence", method: "PATCH")
    }
}

// MARK: - Helpers

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

import UIKit
enum UIDeviceVersion {
    static var current: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }
}
