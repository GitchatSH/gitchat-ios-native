import SwiftUI

private extension View {
    /// iOS 18+ `matchedTransitionSource` so the photo tile becomes
    /// the zoom-in source when the image viewer is pushed via
    /// `navigationTransition(.zoom(sourceID:in:))`. Older OSes fall
    /// through unchanged (the navigation push just slides).
    @ViewBuilder
    func matchedIfActive(url: String, in ns: Namespace.ID?, active: String?) -> some View {
        if let ns {
            if #available(iOS 18.0, macCatalyst 18.0, *) {
                self.matchedTransitionSource(id: "chat.image:\(url)", in: ns)
            } else {
                self
            }
        } else {
            self
        }
    }
}

/// iMessage-style grid for image attachments. Renders 1 / 2 / 3 / 4+
/// layouts with a "+N" overlay on the fourth tile when attachments
/// count exceeds 4. Each tile is `CachedAsyncImage` sized to a pixel
/// target matched to the tile (so downsampling produces an asset
/// that's sharp but not oversized).
///
/// Single-tile layout preserves the source image's intrinsic aspect
/// ratio (so portrait photos stay portrait); 2+ tile layouts crop to
/// square for a predictable grid.
struct ChatAttachmentsGrid: View {
    let attachments: [MessageAttachment]
    let maxWidth: CGFloat
    let isUploading: Bool
    let onTap: (String) -> Void
    /// Namespace used to run a shared-element transition from the
    /// tapped tile to the full-screen viewer. The receiving overlay
    /// marks its copy `isSource: false` with the same `id`, so SwiftUI
    /// animates the frame between the two views.
    var matchedNamespace: Namespace.ID? = nil
    /// URL currently shown in the viewer overlay, if any. Only the tile
    /// matching this URL is marked as the matched transition source;
    /// other tiles stay out of the animation.
    var activePreviewURL: String? = nil
    /// When false, tiles skip their own rounded clip — the parent
    /// bubble's clipShape handles corners instead.
    var applyClip: Bool = true

    private var spacing: CGFloat { applyClip ? 3 : 2 }
    private var corner: CGFloat { applyClip ? 14 : 0 }

    var body: some View {
        switch attachments.count {
        case 0: EmptyView()
        case 1: one(attachments[0])
        case 2: two(attachments)
        case 3: three(attachments)
        default: fourPlus(attachments)
        }
    }

    @ViewBuilder
    private func tile(
        _ a: MessageAttachment,
        width: CGFloat,
        height: CGFloat,
        overlay: String? = nil
    ) -> some View {
        let urlStr = a.url
        let url = URL(string: urlStr)
        ZStack {
            CachedAsyncImage(
                url: url,
                contentMode: .fill,
                placeholder: .filled,
                fitMaxWidth: nil,
                fitMaxHeight: nil,
                maxPixelSize: max(width, height)
            )
            .frame(width: width, height: height)
            .clipped()
            if let overlay {
                Rectangle().fill(Color.black.opacity(0.4))
                Text(overlay)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            if isUploading {
                Rectangle().fill(Color.black.opacity(0.25))
                ProgressView().tint(.white).controlSize(.large)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .contentShape(Rectangle())
        .matchedIfActive(url: urlStr, in: matchedNamespace, active: activePreviewURL)
        .onTapGesture { onTap(urlStr) }
    }

    @ViewBuilder
    private func one(_ a: MessageAttachment) -> some View {
        let url = URL(string: a.url)
        if applyClip {
            // Standalone: fit with own clip
            ZStack {
                CachedAsyncImage(
                    url: url,
                    contentMode: .fit,
                    placeholder: .filled,
                    fitMaxWidth: maxWidth,
                    fitMaxHeight: 320
                )
                if isUploading {
                    Color.black.opacity(0.25)
                    ProgressView().tint(.white).controlSize(.large)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .contentShape(Rectangle())
            .matchedIfActive(url: a.url, in: matchedNamespace, active: activePreviewURL)
            .onTapGesture { onTap(a.url) }
        } else {
            // Inside bubble: fill width, parent clips corners
            let imgHeight = min(maxWidth * 0.75, 320)
            ZStack {
                CachedAsyncImage(
                    url: url,
                    contentMode: .fill,
                    placeholder: .filled,
                    fitMaxWidth: nil,
                    fitMaxHeight: nil,
                    maxPixelSize: maxWidth
                )
                .frame(width: maxWidth, height: imgHeight)
                .clipped()
                if isUploading {
                    Color.black.opacity(0.25)
                    ProgressView().tint(.white).controlSize(.large)
                }
            }
            .frame(width: maxWidth, height: imgHeight)
            .contentShape(Rectangle())
            .matchedIfActive(url: a.url, in: matchedNamespace, active: activePreviewURL)
            .onTapGesture { onTap(a.url) }
        }
    }

    @ViewBuilder
    private func two(_ items: [MessageAttachment]) -> some View {
        let side = (maxWidth - spacing) / 2
        HStack(spacing: spacing) {
            tile(items[0], width: side, height: side)
            tile(items[1], width: side, height: side)
        }
    }

    @ViewBuilder
    private func three(_ items: [MessageAttachment]) -> some View {
        let leftW = (maxWidth - spacing) * 0.62
        let rightW = maxWidth - spacing - leftW
        let rightH = (leftW - spacing) / 2
        HStack(spacing: spacing) {
            tile(items[0], width: leftW, height: leftW)
            VStack(spacing: spacing) {
                tile(items[1], width: rightW, height: rightH)
                tile(items[2], width: rightW, height: rightH)
            }
        }
    }

    @ViewBuilder
    private func fourPlus(_ items: [MessageAttachment]) -> some View {
        let side = (maxWidth - spacing) / 2
        let extra = items.count - 4
        VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                tile(items[0], width: side, height: side)
                tile(items[1], width: side, height: side)
            }
            HStack(spacing: spacing) {
                tile(items[2], width: side, height: side)
                tile(
                    items[3],
                    width: side,
                    height: side,
                    overlay: extra > 0 ? "+\(extra)" : nil
                )
            }
        }
    }
}
