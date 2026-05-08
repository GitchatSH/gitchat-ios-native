import Foundation

/// Pure formatter that produces a one-line preview string and (optional)
/// inline thumbnail URL for a message. Shared between the main app's
/// chat-list row and the OneSignal Notification Service Extension so push
/// banners and the in-app list always agree on what a message looks like
/// in compact form.
///
/// Forward attribution prefers the structured `forwarded_from_original_author`
/// DTO field; falls back to parsing the legacy `> Forwarded from @user\n\n`
/// body prefix so this lands on iOS independently of the backend rollout.
enum MessagePreviewFormatter {
    struct Output: Equatable {
        let text: String
        let thumbURL: URL?
    }

    /// Compose a one-line preview string for a message.
    /// - Parameters:
    ///   - message: the message DTO
    ///   - isGroup: true if the conversation is a group/team/community
    ///   - senderLogin: the immediate sender's login (used as `bob: ` prefix in groups)
    static func format(message: Message, isGroup: Bool, senderLogin: String?) -> Output {
        let raw = message.content

        // Forward attribution: prefer structured field; fall back to parsing
        // the legacy `> Forwarded from @user\n\n` body prefix.
        let originalAuthor: String?
        let bodyAfterForward: String
        if let structured = message.forwarded_from_original_author, !structured.isEmpty {
            originalAuthor = structured
            bodyAfterForward = stripLegacyForwardPrefix(raw)
        } else {
            let parsed = parseLegacyForwardPrefix(raw)
            originalAuthor = parsed.author
            bodyAfterForward = parsed.rest
        }

        // Media label: empty body + attachment → label; attachment + caption → caption.
        let mediaLabeledBody: String = {
            let trimmed = bodyAfterForward.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty, let firstAttachment = message.attachments?.first else {
                return bodyAfterForward
            }
            switch firstAttachment.type ?? "" {
            case "image": return "📷 Photo"
            case "video": return "🎥 Video"
            case "voice": return "🎙 Voice message"
            case "file":  return "📎 \(firstAttachment.filename ?? "File")"
            default:      return bodyAfterForward
            }
        }()

        var text = mediaLabeledBody
        if let originalAuthor {
            text = "↪ @\(originalAuthor): \(text)"
        }
        if isGroup, let senderLogin {
            text = "\(senderLogin): \(text)"
        }

        let thumbURL: URL? = {
            guard let att = message.attachments?.first else { return nil }
            if let s = att.thumbnail_url, let u = URL(string: s) { return u }
            if !att.url.isEmpty, let u = URL(string: att.url) { return u }
            return nil
        }()

        return Output(text: text, thumbURL: thumbURL)
    }

    // MARK: - Legacy forward prefix parsing

    private static let legacyForwardRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(?:>\s+)?Forwarded from @([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))(?:\n+|$)"#,
        options: []
    )

    private static func parseLegacyForwardPrefix(_ raw: String) -> (author: String?, rest: String) {
        guard let regex = legacyForwardRegex else { return (nil, raw) }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges >= 2,
              let authorRange = Range(match.range(at: 1), in: raw),
              let fullRange = Range(match.range(at: 0), in: raw) else {
            return (nil, raw)
        }
        let author = String(raw[authorRange])
        let rest = String(raw[fullRange.upperBound...])
        return (author, rest)
    }

    private static func stripLegacyForwardPrefix(_ raw: String) -> String {
        return parseLegacyForwardPrefix(raw).rest
    }
}
