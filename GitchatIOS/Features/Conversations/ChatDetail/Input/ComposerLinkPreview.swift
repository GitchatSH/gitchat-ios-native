import SwiftUI

/// Shows a link preview card above the composer when the draft
/// contains a URL. Fetches OG metadata via the shared `OGFetcher`.
/// The user can dismiss the preview with the X button; dismissed
/// URLs are remembered for the session so they don't reappear.
struct ComposerLinkPreview: View {
    @Environment(\.chatTheme) private var theme

    /// URLs whose link preview was dismissed by the user.
    /// Checked by `ChatMessageView` to skip rendering `LinkPreviewCard`.
    @MainActor static var suppressedURLs: Set<String> = []

    let url: URL
    let onDismiss: () -> Void

    @State private var og: OGFetcher.OGData?

    init(url: URL, onDismiss: @escaping () -> Void) {
        self.url = url
        self.onDismiss = onDismiss
        _og = State(initialValue: OGFetcher.shared.cached(url))
    }

    var body: some View {
        if let og, og.title != nil || og.imageURL != nil {
            HStack(alignment: .top, spacing: 0) {
                // Thumbnail
                if let imgStr = og.imageURL, let imgURL = URL(string: imgStr) {
                    CachedAsyncImage(url: imgURL, contentMode: .fill, maxPixelSize: 120)
                        .frame(width: 60, height: 60)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.trailing, 10)
                }

                // Text info
                VStack(alignment: .leading, spacing: 2) {
                    if let title = og.title, !title.isEmpty {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                    if let desc = og.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Text(url.host ?? "")
                        .font(.caption2)
                        .foregroundStyle(Color(.tertiaryLabel))
                }

                Spacer()

                // Dismiss button
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } else {
            Color.clear
                .frame(height: 0)
                .onAppear { fetchIfNeeded() }
        }
    }

    private func fetchIfNeeded() {
        guard og == nil else { return }
        if let c = OGFetcher.shared.cached(url) {
            og = c
            return
        }
        OGFetcher.shared.fetch(url) { data in
            DispatchQueue.main.async { og = data }
        }
    }
}
