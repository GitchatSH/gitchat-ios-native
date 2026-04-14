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

struct Message: Decodable, Identifiable, Hashable {
    let id: String
    let conversation_id: String?
    let sender: String
    let sender_avatar: String?
    let content: String
    let created_at: String?
    let edited_at: String?
    let reactions: [MessageReaction]?
    let attachment_url: String?
    let type: String?
    let reply_to_id: String?

    // Decode defensively: backend may send `sender` as a string OR as an
    // object `{ login, avatar_url }`, and may use slightly different keys.
    private enum CodingKeys: String, CodingKey {
        case id, sender, content, type
        case sender_login, senderLogin
        case conversation_id, conversationId
        case sender_avatar, senderAvatar, sender_avatar_url
        case created_at, createdAt
        case edited_at, editedAt
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
        reply_to_id: String?
    ) {
        self.id = id
        self.conversation_id = conversation_id
        self.sender = sender
        self.sender_avatar = sender_avatar
        self.content = content
        self.created_at = created_at
        self.edited_at = edited_at
        self.reactions = reactions
        self.attachment_url = attachment_url
        self.type = type
        self.reply_to_id = reply_to_id
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
        self.reactions = try c.decodeIfPresent([MessageReaction].self, forKey: .reactions)
        self.attachment_url = try c.decodeIfPresent(String.self, forKey: .attachment_url)
            ?? c.decodeIfPresent(String.self, forKey: .attachmentUrl)
        self.type = try c.decodeIfPresent(String.self, forKey: .type)
        self.reply_to_id = try c.decodeIfPresent(String.self, forKey: .reply_to_id)
            ?? c.decodeIfPresent(String.self, forKey: .replyToId)
    }
}

struct MessageReaction: Decodable, Hashable {
    let emoji: String
    let count: Int
    let reacted: Bool
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
