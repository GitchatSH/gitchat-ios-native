import SwiftUI

/// Bar above the composer while the user is replying to or editing
/// a message. Dismiss button cancels reply / edit respectively.
struct ChatReplyEditBar: View {
    @Environment(\.chatTheme) private var theme

    let editing: Message?
    let replyingTo: Message?
    let onDismiss: () -> Void

    /// First image attachment of the reply target — drives the optional
    /// thumbnail to the left of the snippet, mirroring the inline reply
    /// quote on the bubble.
    private var replyThumbURL: URL? {
        guard editing == nil, let target = replyingTo else { return nil }
        guard let raw = target.firstImageAttachmentURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var snippetText: String {
        let raw = (editing ?? replyingTo)?.content ?? ""
        if !raw.isEmpty { return raw }
        return replyThumbURL != nil ? "Photo" : ""
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: editing != nil ? "pencil" : "arrowshape.turn.up.left")
                .foregroundStyle(theme.replyAccent)
            if let url = replyThumbURL {
                CachedAsyncImage(url: url, contentMode: .fill, maxPixelSize: 108)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(editing != nil ? "Editing" : "Replying to \(replyingTo?.sender ?? "")")
                    .font(.caption.bold())
                    .foregroundStyle(theme.replyAccent)
                Text(snippetText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic(((editing ?? replyingTo)?.content ?? "").isEmpty && replyThumbURL != nil)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.clear)
    }
}
