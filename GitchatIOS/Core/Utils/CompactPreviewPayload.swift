import Foundation

/// Pure formatter pipeline for the OneSignal Notification Service Extension:
/// extract structured fields from the OneSignal payload (`userInfo`), feed
/// them through `MessagePreviewFormatter`, and return the formatted body —
/// or `nil` if the body is unchanged / empty (caller should leave content
/// alone).
///
/// Lives in the main-app source tree (and is also compiled into the NSE
/// target via `project.yml`) so it can be unit-tested without touching
/// `UNNotificationContent` or the OneSignal SDK.
enum CompactPreviewPayload {
    /// - Parameters:
    ///   - userInfo: the raw `UNNotificationContent.userInfo` payload
    ///     (OneSignal nests structured data under `custom.a`; falls back
    ///     to `userInfo["data"]` for non-OneSignal-shaped payloads).
    ///   - currentBody: the current `content.body` — used both as the
    ///     synthetic-message content fed to the formatter and as the
    ///     "did anything change?" comparison so we don't rewrite a body
    ///     identical to what we'd produce.
    /// - Returns: the formatted body to apply, or `nil` when the formatter
    ///   produced nothing useful (empty result, or identical to input).
    static func formattedBody(userInfo: [AnyHashable: Any], currentBody: String) -> String? {
        let custom = (userInfo["custom"] as? [String: Any]) ?? [:]
        let data = (custom["a"] as? [String: Any]) ?? (userInfo["data"] as? [String: Any]) ?? [:]

        let forwardedFromOriginalAuthor = data["forwarded_from_original_author"] as? String
        let attachmentThumbUrl = data["attachment_thumb_url"] as? String
        let attachmentType = data["attachment_type"] as? String
        let attachmentFilename = data["attachment_filename"] as? String
        let senderLogin = (data["sender_login"] as? String) ?? (data["actor_login"] as? String)
        let isGroup = (data["is_group"] as? Bool) == true
            || (data["is_group"] as? NSNumber)?.boolValue == true
            || (data["is_group"] as? String) == "true"

        // Synthesize an attachment only when the backend gave us at least one
        // structured attachment field. The formatter checks `!att.url.isEmpty`
        // when picking a thumbnail, so feeding it an empty url would be a no-op
        // that still pays the alloc cost.
        let attachments: [MessageAttachment]?
        if attachmentThumbUrl != nil || attachmentType != nil {
            attachments = [
                MessageAttachment(
                    attachment_id: nil,
                    url: attachmentThumbUrl ?? "",
                    type: attachmentType,
                    filename: attachmentFilename,
                    mime_type: nil,
                    width: nil,
                    height: nil,
                    duration_seconds: nil,
                    thumbnail_url: attachmentThumbUrl
                )
            ]
        } else {
            attachments = nil
        }

        // Throwaway Message — the formatter only reads `content`, `attachments`,
        // and `forwarded_from_original_author`. Everything else is filler. The
        // id is throwaway too (the static doesn't have access to the request
        // identifier the instance method had).
        let synthetic = Message(
            id: UUID().uuidString,
            conversation_id: data["conversation_id"] as? String,
            sender: senderLogin ?? "",
            sender_avatar: nil,
            content: currentBody,
            created_at: nil,
            edited_at: nil,
            reactions: nil,
            attachment_url: nil,
            type: nil,
            reply_to_id: nil,
            attachments: attachments,
            forwarded_from_original_author: forwardedFromOriginalAuthor
        )

        let out = MessagePreviewFormatter.format(
            message: synthetic,
            isGroup: isGroup,
            senderLogin: isGroup ? senderLogin : nil
        )

        // Only rewrite when the formatter actually changed something, and
        // never blank out a backend-provided body with an empty result.
        guard !out.text.isEmpty, out.text != currentBody else { return nil }
        return out.text
    }
}
