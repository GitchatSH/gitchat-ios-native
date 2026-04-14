import Foundation

// MARK: - Envelope

struct APIEnvelope<T: Decodable>: Decodable {
    let data: T?
    let success: Bool?
    let message: String?
    let statusCode: Int?
}

struct EmptyResponse: Decodable {}

// MARK: - Auth

struct AuthLinkRequest: Encodable {
    let github_token: String
    let client_id: String
    let ide: String
    let ide_version: String
}

struct AuthLinkResponse: Decodable {
    let access_token: String
    let login: String
}

// MARK: - Conversation / Message

struct Conversation: Decodable, Identifiable, Hashable {
    let id: String
    let type: String?
    let is_group: Bool?
    let group_name: String?
    let group_avatar_url: String?
    let repo_full_name: String?
    let participants: [ConversationParticipant]?
    let other_user: ConversationParticipant?
    let last_message: Message?
    let last_message_preview: String?
    let last_message_text: String?
    let last_message_at: String?
    let unread_count: Int?
    let pinned: Bool?
    let pinned_at: String?
    let is_request: Bool?
    let updated_at: String?
    let is_muted: Bool?

    var isGroup: Bool { is_group == true || type == "group" || type == "community" || type == "team" }

    var participantsOrEmpty: [ConversationParticipant] { participants ?? [] }
    var unreadCount: Int { unread_count ?? 0 }
    var isPinned: Bool { pinned ?? (pinned_at != nil) }
    var isRequest: Bool { is_request ?? false }

    var previewText: String? {
        last_message_preview ?? last_message_text ?? last_message?.content
    }

    var displayTitle: String {
        if isGroup {
            return group_name ?? participantsOrEmpty.map(\.login).joined(separator: ", ")
        }
        if let u = other_user {
            return u.name ?? u.login
        }
        if let first = participantsOrEmpty.first {
            return first.name ?? first.login
        }
        return "Conversation"
    }

    var displayAvatarURL: String? {
        if isGroup { return group_avatar_url }
        return other_user?.avatar_url ?? participantsOrEmpty.first?.avatar_url
    }
}

struct ConversationListResponse: Decodable {
    let conversations: [Conversation]
    let nextCursor: String?
}

struct ConversationParticipant: Decodable, Identifiable, Hashable {
    var id: String { login }
    let login: String
    let avatar_url: String?
    let name: String?
    let online: Bool?
}

struct ReplyPreview: Decodable, Hashable {
    let id: String
    let body: String?
    let sender_login: String?

    enum CodingKeys: String, CodingKey {
        case id, body
        case sender_login
        case senderLogin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.body = try c.decodeIfPresent(String.self, forKey: .body)
        self.sender_login = try c.decodeIfPresent(String.self, forKey: .sender_login)
            ?? c.decodeIfPresent(String.self, forKey: .senderLogin)
    }
}

struct MessageAttachment: Decodable, Hashable, Identifiable {
    let attachment_id: String?
    let url: String
    let type: String?
    let filename: String?
    let mime_type: String?
    let width: Int?
    let height: Int?

    var id: String { attachment_id ?? url }

    enum CodingKeys: String, CodingKey {
        case attachment_id = "id"
        case url, type, filename, mime_type, width, height
    }
}

struct Message: Decodable, Identifiable, Hashable {
    let id: String
    let conversation_id: String?
    let sender: String
    let sender_avatar: String?
    let content: String
    let created_at: String?
    let edited_at: String?
    let unsent_at: String?
    let reactions: [MessageReaction]?
    let reactionRows: [RawReactionRow]?
    let attachment_url: String?
    let attachments: [MessageAttachment]?
    let type: String?
    let reply_to_id: String?
    let reply: ReplyPreview?

    // Decode defensively: backend may send `sender` as a string OR as an
    // object `{ login, avatar_url }`, and may use slightly different keys.
    private enum CodingKeys: String, CodingKey {
        case id, sender, content, type, reply, attachments
        case sender_login, senderLogin
        case conversation_id, conversationId
        case sender_avatar, senderAvatar, sender_avatar_url
        case created_at, createdAt
        case edited_at, editedAt
        case unsent_at, unsentAt
        case reactions
        case attachment_url, attachmentUrl
        case reply_to_id, replyToId
        case body
    }

    private struct SenderObject: Decodable {
        let login: String?
        let avatar_url: String?
    }

    init(
        id: String,
        conversation_id: String?,
        sender: String,
        sender_avatar: String?,
        content: String,
        created_at: String?,
        edited_at: String?,
        reactions: [MessageReaction]?,
        attachment_url: String?,
        type: String?,
        reply_to_id: String?,
        reply: ReplyPreview? = nil,
        attachments: [MessageAttachment]? = nil,
        unsent_at: String? = nil,
        reactionRows: [RawReactionRow]? = nil
    ) {
        self.id = id
        self.conversation_id = conversation_id
        self.sender = sender
        self.sender_avatar = sender_avatar
        self.content = content
        self.created_at = created_at
        self.edited_at = edited_at
        self.unsent_at = unsent_at
        self.reactions = reactions
        self.reactionRows = reactionRows
        self.attachment_url = attachment_url
        self.attachments = attachments
        self.type = type
        self.reply_to_id = reply_to_id
        self.reply = reply
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.conversation_id = try c.decodeIfPresent(String.self, forKey: .conversation_id)
            ?? c.decodeIfPresent(String.self, forKey: .conversationId)

        // sender: string, object, or separate sender_login field
        if let s = try? c.decode(String.self, forKey: .sender) {
            self.sender = s
            self.sender_avatar = try c.decodeIfPresent(String.self, forKey: .sender_avatar)
                ?? c.decodeIfPresent(String.self, forKey: .senderAvatar)
                ?? c.decodeIfPresent(String.self, forKey: .sender_avatar_url)
        } else if let obj = try? c.decode(SenderObject.self, forKey: .sender) {
            self.sender = obj.login ?? "unknown"
            self.sender_avatar = obj.avatar_url
        } else if let s = try? c.decode(String.self, forKey: .sender_login) {
            self.sender = s
            self.sender_avatar = try c.decodeIfPresent(String.self, forKey: .sender_avatar)
                ?? c.decodeIfPresent(String.self, forKey: .senderAvatar)
                ?? c.decodeIfPresent(String.self, forKey: .sender_avatar_url)
        } else if let s = try? c.decode(String.self, forKey: .senderLogin) {
            self.sender = s
            self.sender_avatar = try c.decodeIfPresent(String.self, forKey: .sender_avatar)
                ?? c.decodeIfPresent(String.self, forKey: .senderAvatar)
                ?? c.decodeIfPresent(String.self, forKey: .sender_avatar_url)
        } else {
            self.sender = "unknown"
            self.sender_avatar = nil
        }

        // content: `content` or `body`
        self.content = (try? c.decode(String.self, forKey: .content))
            ?? (try? c.decode(String.self, forKey: .body))
            ?? ""
        self.created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
            ?? c.decodeIfPresent(String.self, forKey: .createdAt)
        self.edited_at = try c.decodeIfPresent(String.self, forKey: .edited_at)
            ?? c.decodeIfPresent(String.self, forKey: .editedAt)
        self.unsent_at = try c.decodeIfPresent(String.self, forKey: .unsent_at)
            ?? c.decodeIfPresent(String.self, forKey: .unsentAt)
        self.attachments = try c.decodeIfPresent([MessageAttachment].self, forKey: .attachments)
        // Backend returns raw reaction rows ({emoji, userLogin, ...}) not the
        // aggregated {emoji, count, reacted} shape. Try structured decode first,
        // otherwise aggregate raw rows manually. Never fail the whole message.
        if let decoded = try? c.decodeIfPresent([MessageReaction].self, forKey: .reactions) {
            self.reactions = decoded
            self.reactionRows = nil
        } else if let raw = try? c.decodeIfPresent([RawReactionRow].self, forKey: .reactions) {
            var counts: [String: Int] = [:]
            for row in raw { counts[row.emoji, default: 0] += 1 }
            self.reactions = counts.map { MessageReaction(emoji: $0.key, count: $0.value, reacted: false) }
            self.reactionRows = raw
        } else {
            self.reactions = nil
            self.reactionRows = nil
        }
        self.attachment_url = try c.decodeIfPresent(String.self, forKey: .attachment_url)
            ?? c.decodeIfPresent(String.self, forKey: .attachmentUrl)
        self.type = try c.decodeIfPresent(String.self, forKey: .type)
        self.reply_to_id = try c.decodeIfPresent(String.self, forKey: .reply_to_id)
            ?? c.decodeIfPresent(String.self, forKey: .replyToId)
        self.reply = try? c.decodeIfPresent(ReplyPreview.self, forKey: .reply)
    }
}

struct MessageReaction: Decodable, Hashable {
    let emoji: String
    let count: Int
    let reacted: Bool
}

struct RawReactionRow: Decodable, Hashable {
    let emoji: String
    let user_login: String?

    enum CodingKeys: String, CodingKey {
        case emoji
        case user_login
        case userLogin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.emoji = try c.decode(String.self, forKey: .emoji)
        self.user_login = try c.decodeIfPresent(String.self, forKey: .user_login)
            ?? c.decodeIfPresent(String.self, forKey: .userLogin)
    }
}

struct MessagesResponse: Decodable {
    let messages: [Message]
    let cursor: String?
    let nextCursor: String?
    let previousCursor: String?
    let otherReadAt: String?
}

struct CreateConversationRequest: Encodable {
    let recipient_login: String?
    let recipient_logins: [String]?
    let group_name: String?
}

struct SendMessageRequest: Encodable {
    let body: String
    let reply_to_id: String?
}

// MARK: - Profile

struct UserProfile: Decodable, Hashable {
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
    let star_power: Int?
    let top_repos: [RepoSummary]?
    let created_at: String?
}

/// Minimal user shape returned by /following, /followers, /messages/search-users, etc.
struct FriendUser: Decodable, Identifiable, Hashable {
    var id: String { login }
    let login: String
    let name: String?
    let avatar_url: String?
    let online: Bool?
}

struct RepoSummary: Decodable, Hashable, Identifiable {
    var id: String { full_name }
    let full_name: String
    let description: String?
    let stars: Int?
    let language: String?
}

struct FollowStatus: Decodable, Hashable {
    let following: Bool
    let followed_by: Bool

    enum CodingKeys: String, CodingKey {
        case following
        case followed_by = "followedBy"
    }
}

// MARK: - Notifications

struct Notification: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let actor_login: String
    let actor_avatar_url: String?
    let actor_name: String?
    let metadata: NotificationMetadata?
    let is_read: Bool
    let created_at: String
}

struct NotificationMetadata: Decodable, Hashable {
    let conversationId: String?
    let messageId: String?
    let preview: String?
    let repoFullName: String?
    let eventType: String?
}

struct NotificationListResponse: Decodable {
    let data: [Notification]
    let nextCursor: String?
    let unreadCount: Int?
}

// MARK: - Channels

struct RepoChannel: Decodable, Identifiable, Hashable {
    let id: String
    let repoOwner: String
    let repoName: String
    let displayName: String?
    let description: String?
    let avatarUrl: String?
    let subscriberCount: Int
    let role: String?
}

struct ChannelListResponse: Decodable {
    let channels: [RepoChannel]
    let nextCursor: String?
}

// MARK: - Presence

struct PresenceResponse: Decodable {
    let presence: [String: String?]
}
