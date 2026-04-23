import SwiftUI

/// Sits above the composer when the user is either replying to a
/// message or editing one of their own. Shows a brief preview of the
/// source message plus a dismiss button.
struct ReplyEditBar: View {
    let editing: Message?
    let replyingTo: Message?
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: editing != nil ? "pencil" : "arrowshape.turn.up.left")
                .foregroundStyle(Color("AccentColor"))
            VStack(alignment: .leading, spacing: 2) {
                Text(editing != nil ? "Editing" : "Replying to \(replyingTo?.sender ?? "")")
                    .font(.caption.bold())
                    .foregroundStyle(Color("AccentColor"))
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
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}
