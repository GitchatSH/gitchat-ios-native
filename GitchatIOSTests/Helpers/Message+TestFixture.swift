import Foundation
@testable import Gitchat

extension Message {
    /// Convenience factory for test fixtures. All parameters have sensible
    /// defaults; override only what matters for a given test.
    static func testFixture(
        id: String = "srv-1",
        clientMessageID: String? = nil,
        conversationID: String = "c1",
        sender: String = "alice",
        content: String = "hi"
    ) -> Message {
        Message(
            id: id,
            client_message_id: clientMessageID,
            conversation_id: conversationID,
            sender: sender,
            sender_avatar: nil,
            content: content,
            created_at: "2026-04-28T10:00:00.000Z",
            edited_at: nil,
            reactions: nil,
            attachment_url: nil,
            type: "user",
            reply_to_id: nil,
            reply: nil,
            attachments: nil,
            unsent_at: nil,
            reactionRows: nil
        )
    }
}
