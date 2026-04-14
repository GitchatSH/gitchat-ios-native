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
    let participants: [ConversationParticipant]
    let last_message: Message?
    let last_message_preview: String?
    let last_message_at: String?
    let unread_count: Int
    let pinned: Bool
    let is_request: Bool
    let updated_at: String
    let is_muted: Bool?

    var isGroup: Bool { is_group == true || type == "group" || type == "community" || type == "team" }

    var displayTitle: String {
        if isGroup {
            return group_name ?? participants.map(\.login).joined(separator: ", ")
        }
        return participants.first?.name ?? participants.first?.login ?? "Conversation"
    }

    var displayAvatarURL: String? {
        if isGroup { return group_avatar_url }
        return participants.first?.avatar_url
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
    let created_at: String
    let edited_at: String?
    let reactions: [MessageReaction]?
    let attachment_url: String?
    let type: String?
    let reply_to_id: String?
}

struct MessageReaction: Decodable, Hashable {
    let emoji: String
    let count: Int
    let reacted: Bool
}

struct MessagesResponse: Decodable {
    let messages: [Message]
    let cursor: String?
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
