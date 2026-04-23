import SwiftUI

/// Inline reply-preview bubble rendered above a message body when the
/// message has a `reply` field. Tap jumps + pulses the target in the
/// list.
struct ChatReplyPreview: View {
    @Environment(\.chatTheme) private var theme

    let reply: ReplyPreview
    let isMe: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isMe ? theme.replyAccent : Color.secondary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if let login = reply.sender_login {
                    Text("@\(login)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isMe ? theme.replyAccent : Color.secondary)
                }
                Text(reply.body ?? "…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
