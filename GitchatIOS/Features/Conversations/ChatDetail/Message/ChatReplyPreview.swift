import SwiftUI

/// Inline reply-preview bubble rendered above a message body when the
/// message has a `reply` field. Tap jumps + pulses the target in the
/// list.
struct ChatReplyPreview: View {
    @Environment(\.chatTheme) private var theme

    let reply: ReplyPreview
    let isMe: Bool
    let onTap: () -> Void

    private var thumbURL: URL? {
        guard let raw = reply.first_image_url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var bodyText: String {
        if let body = reply.body, !body.isEmpty { return body }
        // Image-only target: fall back to "Photo" label so the snippet line
        // isn't a lonely ellipsis.
        return thumbURL != nil ? "Photo" : "…"
    }

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isMe ? theme.replyAccent : Color.secondary)
                .frame(width: 3)
            if let url = thumbURL {
                CachedAsyncImage(url: url, contentMode: .fill, maxPixelSize: 96)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 1) {
                if let login = reply.sender_login {
                    Text("@\(login)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isMe ? theme.replyAccent : Color.secondary)
                }
                Text(bodyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .italic(reply.body?.isEmpty != false && thumbURL != nil)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.replyBackground, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
