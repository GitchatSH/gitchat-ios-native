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

    struct ExchangeCodeRequest: Encodable {
        let code: String
        let redirect_uri: String
        let client_id: String
        let ide: String
        let ide_version: String
    }

    func exchangeGithubCode(code: String, redirectURI: String) async throws -> AuthLinkResponse {
        let body = ExchangeCodeRequest(
            code: code,
            redirect_uri: redirectURI,
            client_id: "gitchat-ios@\(Config.appVersion)",
            ide: "ios",
            ide_version: UIDeviceVersion.current
        )
        return try await request("auth/github-exchange-code", method: "POST", body: body, requireAuth: false)
    }

    struct AppleLinkRequest: Encodable {
        let identity_token: String
        let first_name: String?
        let last_name: String?
        let client_id: String
        let ide: String
        let ide_version: String
    }

    struct AppleLinkResponse: Decodable {
        let access_token: String
        let login: String
        let needs_github_link: Bool
    }

    func appleLink(identityToken: String, firstName: String?, lastName: String?) async throws -> AppleLinkResponse {
        let body = AppleLinkRequest(
            identity_token: identityToken,
            first_name: firstName,
            last_name: lastName,
            client_id: "gitchat-ios@\(Config.appVersion)",
            ide: "ios",
            ide_version: UIDeviceVersion.current
        )
        return try await request("auth/apple-link", method: "POST", body: body, requireAuth: false)
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

    func createConversation(recipient: String) async throws -> Conversation {
        let req = CreateConversationRequest(recipient_login: recipient, recipient_logins: nil, group_name: nil)
        return try await request("messages/conversations", method: "POST", body: req)
    }

    func createGroup(recipients: [String], name: String?) async throws -> Conversation {
        let req = CreateConversationRequest(recipient_login: nil, recipient_logins: recipients, group_name: name)
        return try await request("messages/conversations", method: "POST", body: req)
    }

    func pinConversation(id: String) async throws {
        let _: EmptyResponse = try await request("messages/conversations/\(id)/pin", method: "POST")
    }
    func unpinConversation(id: String) async throws {
        let _: EmptyResponse = try await request("messages/conversations/\(id)/pin", method: "DELETE")
    }
    func deleteConversation(id: String) async throws {
        let _: EmptyResponse = try await request("messages/conversations/\(id)/delete", method: "POST")
    }

    func markRead(conversationId: String) async throws {
        let _: EmptyResponse = try await request("messages/conversations/\(conversationId)/read", method: "PATCH")
    }

    func editMessage(conversationId: String, messageId: String, body: String) async throws {
        struct Body: Encodable { let body: String }
        let _: EmptyResponse = try await request(
            "messages/conversations/\(conversationId)/messages/\(messageId)",
            method: "PATCH",
            body: Body(body: body)
        )
    }

    func deleteMessage(conversationId: String, messageId: String) async throws {
        let _: EmptyResponse = try await request(
            "messages/conversations/\(conversationId)/messages/\(messageId)",
            method: "DELETE"
        )
    }

    func pinMessage(conversationId: String, messageId: String) async throws {
        let _: EmptyResponse = try await request(
            "messages/conversations/\(conversationId)/messages/\(messageId)/pin",
            method: "POST"
        )
    }

    func unpinMessage(conversationId: String, messageId: String) async throws {
        let _: EmptyResponse = try await request(
            "messages/conversations/\(conversationId)/messages/\(messageId)/pin",
            method: "DELETE"
        )
    }

    /// Flag a message as inappropriate. Backend route: POST /messages/:id/report.
    func reportMessage(messageId: String, reason: String, detail: String?) async throws {
        struct Body: Encodable { let reason: String; let detail: String? }
        let _: EmptyResponse = try await request(
            "messages/\(messageId)/report",
            method: "POST",
            body: Body(reason: reason, detail: detail)
        )
    }

    /// Upload a file to a conversation. Returns the attachment URL the
    /// backend will recognize when passed in `sendMessage(..., attachmentURL:)`.
    func uploadAttachment(
        data: Data,
        filename: String,
        mimeType: String,
        conversationId: String
    ) async throws -> String {
        let boundary = "gitchat-\(UUID().uuidString)"
        var req = URLRequest(url: Config.apiBaseURL.appendingPathComponent("messages/upload"))
        req.httpMethod = "POST"
        guard let token = await AuthStore.shared.accessToken else { throw APIError.notAuthenticated }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"conversation_id\"\r\n\r\n\(conversationId)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let (respData, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: respData, encoding: .utf8))
        }
        struct Wrap: Decodable { let data: Inner?; let url: String? }
        struct Inner: Decodable { let url: String }
        let w = try decoder.decode(Wrap.self, from: respData)
        if let url = w.data?.url ?? w.url { return url }
        throw APIError.decoding(NSError(domain: "upload", code: 0, userInfo: [NSLocalizedDescriptionKey: "no url in response"]))
    }

    func sendMessage(
        conversationId: String,
        body: String,
        replyTo: String? = nil,
        attachmentURL: String? = nil,
        attachmentURLs: [String]? = nil
    ) async throws -> Message {
        struct Body: Encodable {
            let body: String
            let reply_to_id: String?
            let attachments: [[String: String]]?
        }
        var attachments: [[String: String]]? = nil
        if let many = attachmentURLs, !many.isEmpty {
            attachments = many.map { ["url": $0] }
        } else if let single = attachmentURL {
            attachments = [["url": single]]
        }
        let req = Body(body: body, reply_to_id: replyTo, attachments: attachments)
        return try await request("messages/conversations/\(conversationId)", method: "POST", body: req)
    }

    func unsendMessage(messageId: String) async throws {
        let _: EmptyResponse = try await request("messages/\(messageId)/unsend", method: "POST")
    }

    func forwardMessage(messageId: String, toConversationIds: [String]) async throws {
        struct Body: Encodable { let conversation_ids: [String] }
        let _: EmptyResponse = try await request(
            "messages/\(messageId)/forward",
            method: "POST",
            body: Body(conversation_ids: toConversationIds)
        )
    }

    func muteConversation(id: String) async throws {
        let _: EmptyResponse = try await request("messages/conversations/\(id)/mute", method: "POST")
    }

    func unmuteConversation(id: String) async throws {
        let _: EmptyResponse = try await request("messages/conversations/\(id)/mute", method: "DELETE")
    }

    func searchMessagesInConversation(id: String, q: String) async throws -> [Message] {
        struct Wrap: Decodable { let messages: [Message]?; let data: Inner? }
        struct Inner: Decodable { let messages: [Message] }
        let w: Wrap = try await request(
            "messages/conversations/\(id)/search",
            query: [URLQueryItem(name: "q", value: q)]
        )
        return w.messages ?? w.data?.messages ?? []
    }

    func pinnedMessages(conversationId: String) async throws -> [Message] {
        // Backend returns a raw array of pin wrappers:
        // [{ id, conversation_id, message_id, pinned_by, pinned_at, message: Message }, ...]
        struct PinWrapper: Decodable {
            let message_id: String
            let pinned_at: String?
            let pinned_by: String?
            let message: Message
        }
        let wrappers: [PinWrapper] = try await request(
            "messages/conversations/\(conversationId)/pinned-messages"
        )
        return wrappers.map(\.message)
    }

    // Channel feeds
    struct ChannelPost: Decodable, Identifiable, Hashable {
        let id: String
        let platform: String?
        let authorHandle: String?
        let authorName: String?
        let authorAvatar: String?
        let body: String?
        let mediaUrls: [String]?
        let platformCreatedAt: String?
    }

    struct ChannelFeedResponse: Decodable {
        let posts: [ChannelPost]
        let nextCursor: String?
    }

    func channelFeed(channelId: String, source: String, cursor: String? = nil) async throws -> ChannelFeedResponse {
        var q: [URLQueryItem] = []
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        q.append(URLQueryItem(name: "limit", value: "30"))
        return try await request("channels/\(channelId)/feed/\(source)", query: q, requireAuth: false)
    }

    func react(messageId: String, emoji: String, add: Bool) async throws {
        struct Body: Encodable { let emoji: String; let message_id: String }
        let _: EmptyResponse = try await request(
            "messages/reactions",
            method: add ? "POST" : "DELETE",
            body: Body(emoji: emoji, message_id: messageId)
        )
    }

    // User search (for starting conversations)
    func searchUsersForDM(query: String) async throws -> [FriendUser] {
        struct Wrap: Decodable { let users: [FriendUser] }
        let w: Wrap = try await request(
            "messages/search-users",
            query: [URLQueryItem(name: "q", value: query)]
        )
        return w.users
    }

    // Profile
    func myProfile() async throws -> UserProfile {
        try await request("user/profile")
    }

    func userProfile(login: String) async throws -> UserProfile {
        struct NestedRepo: Decodable {
            let owner: String
            let name: String
            let description: String?
            let stars: Int?
            let language: String?
        }
        struct NestedProfile: Decodable {
            let login: String
            let name: String?
            let avatar_url: String?
            let bio: String?
            let company: String?
            let location: String?
            let blog: String?
            let followers: Int?
            let following: Int?
            let public_repos: Int?
            let created_at: String?
        }
        struct NestedResponse: Decodable {
            let profile: NestedProfile
            let repos: [NestedRepo]?
        }
        let resp: NestedResponse = try await request("user/\(login)")
        let tops = (resp.repos ?? []).prefix(10).map {
            RepoSummary(
                full_name: "\($0.owner)/\($0.name)",
                description: $0.description,
                stars: $0.stars,
                language: $0.language
            )
        }
        return UserProfile(
            login: resp.profile.login,
            name: resp.profile.name,
            avatar_url: resp.profile.avatar_url,
            bio: resp.profile.bio,
            company: resp.profile.company,
            location: resp.profile.location,
            blog: resp.profile.blog,
            followers: resp.profile.followers,
            following: resp.profile.following,
            public_repos: resp.profile.public_repos,
            star_power: nil,
            top_repos: Array(tops),
            created_at: resp.profile.created_at
        )
    }

    // Following
    func follow(login: String) async throws {
        let _: EmptyResponse = try await request("follow/\(login)", method: "PUT")
    }
    func unfollow(login: String) async throws {
        let _: EmptyResponse = try await request("follow/\(login)", method: "DELETE")
    }
    func followStatus(login: String) async throws -> FollowStatus {
        try await request("follow/\(login)")
    }
    func reportUser(login: String, reason: String, detail: String?) async throws {
        struct Body: Encodable { let reason: String; let detail: String? }
        let _: EmptyResponse = try await request(
            "user/\(login)/report",
            method: "POST",
            body: Body(reason: reason, detail: detail)
        )
    }
    func syncGitHubFollows() async throws {
        let _: EmptyResponse = try await request("following/sync", method: "POST")
    }
    func followingList() async throws -> [FriendUser] {
        struct Wrap: Decodable { let users: [FriendUser] }
        let w: Wrap = try await request("following", query: [URLQueryItem(name: "per_page", value: "100")])
        return w.users
    }

    // Public follow lists for any user — backend returns richer shape, map to FriendUser.
    private struct PublicFollowUser: Decodable {
        let login: String
        let name: String?
        let avatar_url: String?
    }
    private struct PublicFollowList: Decodable {
        let users: [PublicFollowUser]
    }

    func followingList(login: String) async throws -> [FriendUser] {
        let w: PublicFollowList = try await request(
            "following",
            query: [
                URLQueryItem(name: "login", value: login),
                URLQueryItem(name: "per_page", value: "100")
            ],
            requireAuth: false
        )
        return w.users.map { FriendUser(login: $0.login, name: $0.name, avatar_url: $0.avatar_url, online: nil) }
    }

    func followersList(login: String) async throws -> [FriendUser] {
        let w: PublicFollowList = try await request(
            "followers",
            query: [
                URLQueryItem(name: "login", value: login),
                URLQueryItem(name: "per_page", value: "100")
            ],
            requireAuth: false
        )
        return w.users.map { FriendUser(login: $0.login, name: $0.name, avatar_url: $0.avatar_url, online: nil) }
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

    func markNotificationsRead(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        struct Body: Encodable { let ids: [String] }
        let _: EmptyResponse = try await request("notifications/read", method: "PATCH", body: Body(ids: ids))
    }

    // Channels
    func channels() async throws -> ChannelListResponse {
        try await request("channels")
    }

    // Presence
    func heartbeat() async throws {
        let _: EmptyResponse = try await request("presence", method: "PATCH")
    }

    func getPresence(logins: [String]) async throws -> [String: String?] {
        guard !logins.isEmpty else { return [:] }
        struct Resp: Decodable { let presence: [String: String?] }
        let list = logins.joined(separator: ",")
        let encoded = list.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? list
        let resp: Resp = try await request("presence?logins=\(encoded)")
        return resp.presence
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
