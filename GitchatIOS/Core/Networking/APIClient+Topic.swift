import Foundation

// MARK: - Endpoint path / query builders (testable)

enum TopicEndpoints {
    static func list(parentId: String) -> String {
        "messages/conversations/\(parentId)/topics"
    }
    static func create(parentId: String) -> String {
        "messages/conversations/\(parentId)/topics"
    }
    static func archive(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/archive"
    }
    static func read(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/read"
    }
    static func sendMessage(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/messages"
    }
    static func fetchMessages(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/messages"
    }

    /// Only send `includeArchived` / `pinnedOnly` when true.
    /// BE bug: `ListTopicsQueryDto` uses `@Type(() => Boolean)` on these
    /// fields, but `Boolean("false") === true` in JavaScript (any non-empty
    /// string is truthy). Sending `?pinnedOnly=false` is interpreted as
    /// `pinnedOnly=true` server-side, filtering out unpinned topics.
    /// Defaults on BE are already `false`, so omitting the params yields
    /// the correct behaviour.
    static func listQuery(includeArchived: Bool, pinnedOnly: Bool, limit: Int) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if includeArchived {
            items.append(URLQueryItem(name: "includeArchived", value: "true"))
        }
        if pinnedOnly {
            items.append(URLQueryItem(name: "pinnedOnly", value: "true"))
        }
        return items
    }
}

// MARK: - APIClient extension

extension APIClient {

    struct CreateTopicBody: Encodable {
        let name: String
        let iconEmoji: String?
        let colorToken: String?
    }

    func fetchTopics(parentId: String,
                     includeArchived: Bool = false,
                     pinnedOnly: Bool = false,
                     limit: Int = 100) async throws -> [Topic] {
        // BE listTopics returns TopicResponseDto[] directly (no { topics: [...] }
        // wrapper). NestJS TransformInterceptor wraps it as { data: [...], statusCode,
        // message }, which APIClient.request unwraps via APIEnvelope<[Topic]>.
        return try await request(
            TopicEndpoints.list(parentId: parentId),
            query: TopicEndpoints.listQuery(includeArchived: includeArchived,
                                            pinnedOnly: pinnedOnly, limit: limit)
        )
    }

    func createTopic(parentId: String,
                     name: String,
                     iconEmoji: String?,
                     colorToken: String?) async throws -> Topic {
        try await request(
            TopicEndpoints.create(parentId: parentId),
            method: "POST",
            body: CreateTopicBody(name: name, iconEmoji: iconEmoji, colorToken: colorToken)
        )
    }

    func archiveTopic(parentId: String, topicId: String) async throws -> Topic {
        try await request(TopicEndpoints.archive(parentId: parentId, topicId: topicId),
                          method: "PATCH",
                          body: EmptyBody())
    }

    // Pin/unpin is intentionally NOT exposed: topic pin is per-device,
    // persisted locally in TopicListStore (matches the VS Code extension's
    // webview-state pin model). Calling BE pin/unpin requires admin/owner
    // role and is not what the user expects.

    func markTopicRead(parentId: String, topicId: String) async throws {
        let _: EmptyResponse = try await request(
            TopicEndpoints.read(parentId: parentId, topicId: topicId),
            method: "PATCH",
            body: EmptyBody()
        )
    }

    /// Path-based variant of getConversationMessages. Use this when the
    /// endpoint isn't /messages/conversations/{id} — e.g. topic message paths.
    func getMessages(at path: String,
                     cursor: String? = nil,
                     limit: Int = 30) async throws -> MessagesResponse {
        var q = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await request(path, query: q)
    }

    /// Path-based variant of sendMessage with full attachment payload +
    /// idempotency. Mirrors the conversationID-keyed protocol method in
    /// `APIClient+Protocol.swift` but lets the caller supply an arbitrary
    /// endpoint path — used for topic message sends, where the URL has the
    /// `/topics/{topicId}` segment that the protocol method can't express.
    func sendMessage(
        at path: String,
        body: String,
        attachments: [[String: Any]],
        replyToID: String?,
        clientMessageID: String?
    ) async throws -> Message {
        var jsonObj: [String: Any] = ["body": body]
        if let replyToID { jsonObj["reply_to_id"] = replyToID }
        if let clientMessageID { jsonObj["client_message_id"] = clientMessageID }
        let validAttachments = attachments.filter { ($0["url"] as? String) != nil }
        if !validAttachments.isEmpty { jsonObj["attachments"] = validAttachments }

        let jsonData = try JSONSerialization.data(withJSONObject: jsonObj)

        var req = URLRequest(url: Config.apiBaseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        guard let token = await AuthStore.shared.accessToken else { throw APIError.notAuthenticated }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1, nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        if let wrapped = try? decoder.decode(APIEnvelope<Message>.self, from: data), let inner = wrapped.data {
            return inner
        }
        return try decoder.decode(Message.self, from: data)
    }
}

private struct EmptyBody: Encodable {}
