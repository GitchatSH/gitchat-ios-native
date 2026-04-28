import Foundation
@testable import Gitchat

extension Conversation {
    static func fixture(id: String) -> Conversation {
        Conversation(
            id: id, type: "dm", is_group: false, group_name: nil,
            group_avatar_url: nil, repo_full_name: nil, participants: [],
            other_user: nil, last_message: nil, last_message_preview: nil,
            last_message_text: nil, last_message_at: nil, unread_count: 0,
            pinned: false, pinned_at: nil, is_request: false, updated_at: nil,
            is_muted: false, has_mention: false, has_reaction: false,
            topics_enabled: nil,
            has_topics: nil,
            topic_chips: nil
        )
    }
}

extension Topic {
    static func fixture(id: String, parentId: String, isGeneral: Bool = false,
                        pinOrder: Int? = nil, unread: Int = 0) -> Topic {
        Topic(id: id, parent_conversation_id: parentId, name: "T",
              icon_emoji: nil, color_token: nil, is_general: isGeneral,
              pin_order: pinOrder, archived_at: nil,
              last_message_at: nil, last_message_preview: nil, last_sender_login: nil,
              unread_count: unread, unread_mentions_count: 0, unread_reactions_count: 0,
              created_by: "x", created_at: "2026-04-20T08:00:00Z")
    }
}
