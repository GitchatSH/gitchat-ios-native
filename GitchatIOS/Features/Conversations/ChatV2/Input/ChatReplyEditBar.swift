import SwiftUI

/// Bar above the composer while the user is replying to or editing
/// a message. Dismiss button cancels reply / edit respectively.
struct ChatReplyEditBar: View {
    @Environment(\.chatTheme) private var theme

    let editing: Message?
    let replyingTo: Message?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: editing != nil ? "pencil" : "arrowshape.turn.up.left")
                .foregroundStyle(theme.replyAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(editing != nil ? "Editing" : "Replying to \(replyingTo?.sender ?? "")")
                    .font(.caption.bold())
                    .foregroundStyle(theme.replyAccent)
                Text((editing ?? replyingTo)?.content ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.composerSurface)
    }
}
