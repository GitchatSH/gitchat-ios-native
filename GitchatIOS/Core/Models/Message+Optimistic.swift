import Foundation

// MARK: - Optimistic message factory
//
// Lives in its own file so `Models.swift` remains free of dependencies
// outside Foundation and can be safely linked into the OneSignal
// Notification Service Extension target. `PendingAttachment` is defined
// in the outbox layer (`GitchatIOS/Core/OutboxStore.swift`) and is not
// part of the NSE's source set.

extension Message {
    /// Creates a local-only optimistic Message for immediate UI display
    /// before the server confirms delivery. id = "local-<cmid>",
    /// client_message_id = cmid. Used by ChatViewModel.send(content:attachments:replyTo:).
    static func optimistic(
        clientMessageID: String,
        conversationID: String,
        sender: String,
        content: String,
        attachments: [PendingAttachment]
    ) -> Message {
        let localAttachments: [MessageAttachment]? = attachments.isEmpty ? nil :
            attachments.map { att in
                MessageAttachment(
                    attachment_id: att.clientAttachmentID,
                    url: "",
                    type: att.mimeType.hasPrefix("image/") ? "image" : "file",
                    filename: nil,
                    mime_type: att.mimeType,
                    width: att.width,
                    height: att.height,
                    duration_seconds: nil,
                    thumbnail_url: nil
                )
            }
        return Message(
            id: "local-\(clientMessageID)",
            client_message_id: clientMessageID,
            conversation_id: conversationID,
            sender: sender,
            sender_avatar: nil,
            content: content,
            created_at: ISO8601DateFormatter().string(from: Date()),
            edited_at: nil,
            reactions: nil,
            attachment_url: nil,
            type: "user",
            reply_to_id: nil,
            reply: nil,
            attachments: localAttachments,
            unsent_at: nil,
            reactionRows: nil
        )
    }
}
