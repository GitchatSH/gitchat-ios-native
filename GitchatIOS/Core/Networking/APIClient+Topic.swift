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
    static func pin(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/pin"
    }
    static func unpin(parentId: String, topicId: String) -> String {
        "messages/conversations/\(parentId)/topics/\(topicId)/unpin"
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

    struct PinTopicBody: Encodable { let order: Int }

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

    func pinTopic(parentId: String, topicId: String, order: Int) async throws -> Topic {
        try await request(TopicEndpoints.pin(parentId: parentId, topicId: topicId),
                          method: "PATCH",
                          body: PinTopicBody(order: order))
    }

    func unpinTopic(parentId: String, topicId: String) async throws -> Topic {
        try await request(TopicEndpoints.unpin(parentId: parentId, topicId: topicId),
                          method: "PATCH",
                          body: EmptyBody())
    }

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

    /// Path-based variant of sendMessage. Use this when the endpoint isn't
    /// /messages/conversations/{id} — e.g. topic message paths.
    func sendMessage(at path: String,
                     body: String,
                     replyTo: String? = nil,
                     attachmentURL: String? = nil,
                     attachmentURLs: [String]? = nil) async throws -> Message {
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
        return try await request(path, method: "POST", body: req)
    }
}

private struct EmptyBody: Encodable {}
