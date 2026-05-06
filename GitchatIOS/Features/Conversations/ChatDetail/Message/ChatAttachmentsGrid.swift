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

    @State private var videoToPlay: URLItem? = nil

    private var spacing: CGFloat { applyClip ? 3 : 2 }
    private var corner: CGFloat { applyClip ? 14 : 0 }

    var body: some View {
        Group {
            switch attachments.count {
            case 0: EmptyView()
            case 1: one(attachments[0])
            case 2: two(attachments)
            case 3: three(attachments)
            default: fourPlus(attachments)
            }
        }
        .sheet(item: $videoToPlay) { item in
            VideoPlayerView(url: item.url)
        }
    }

    // MARK: - Duration badge helper

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Video tile

    @ViewBuilder
    private func videoTile(
        _ a: MessageAttachment,
        width: CGFloat,
        height: CGFloat,
        overlay: String? = nil
    ) -> some View {
        let posterURL: URL? = {
            if let thumbStr = a.thumbnail_url { return URL(string: thumbStr) }
            // Fall back to the attachment url itself if it looks like an image
            if a.mime_type?.hasPrefix("image/") == true { return URL(string: a.url) }
            return nil
        }()
        ZStack {
            if let posterURL {
                CachedAsyncImage(
                    url: posterURL,
                    contentMode: .fill,
                    placeholder: .filled,
                    fitMaxWidth: nil,
                    fitMaxHeight: nil,
                    maxPixelSize: max(width, height)
                )
                .frame(width: width, height: height)
                .clipped()
            } else {
                Color.black
                    .frame(width: width, height: height)
            }
            // Overlay dimming
            Rectangle().fill(Color.black.opacity(0.15))
            // Play button
            Image(systemName: "play.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 4)
            // "+N" overlay for 4+ grid
            if let overlay {
                Rectangle().fill(Color.black.opacity(0.4))
                Text(overlay)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            // Duration badge
            if let dur = a.duration_seconds {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(formatDuration(dur))
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(6)
                    }
                }
            }
            if isUploading {
                Rectangle().fill(Color.black.opacity(0.25))
                ProgressView().tint(.white).controlSize(.large)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isUploading, let url = URL(string: a.url), !a.url.isEmpty else { return }
            videoToPlay = URLItem(url: url)
        }
    }

    // MARK: - Image tile

    @ViewBuilder
    private func tile(
        _ a: MessageAttachment,
        width: CGFloat,
        height: CGFloat,
        overlay: String? = nil
    ) -> some View {
        let isVideo = a.type == "video" || a.mime_type?.hasPrefix("video/") == true
        if isVideo {
            videoTile(a, width: width, height: height, overlay: overlay)
        } else {
            imageTile(a, width: width, height: height, overlay: overlay)
        }
    }

    @ViewBuilder
    private func imageTile(
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
        let isVideo = a.type == "video" || a.mime_type?.hasPrefix("video/") == true
        if isVideo {
            // Video: use a fixed 16:9 tile with poster frame + play button
            let videoHeight = min(maxWidth * 9 / 16, 240)
            videoTile(a, width: maxWidth, height: videoHeight)
        } else {
            let url = URL(string: a.url)
            if applyClip {
                // Stable frame from intrinsic dimensions so cell height doesn't
                // shift during the brief `.task` initial-frame placeholder
                // window before CachedAsyncImage's load() resolves. Without this,
                // the standalone path's placeholder is a min(maxW,maxH) square
                // and the loaded image is fitted-aspect — cell visibly resizes.
                // See spec 2026-05-04-chat-send-jank-fix-design §2.6.
                let fittedSize: CGSize? = {
                    guard let w = a.width, let h = a.height, w > 0, h > 0 else { return nil }
                    let aspect = CGFloat(w) / CGFloat(h)
                    let maxH: CGFloat = 320
                    if aspect >= 1 {
                        let fw = min(maxWidth, CGFloat(w))
                        return CGSize(width: fw, height: fw / aspect)
                    } else {
                        let fh = min(maxH, CGFloat(h))
                        return CGSize(width: fh * aspect, height: fh)
                    }
                }()
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
                .frame(width: fittedSize?.width, height: fittedSize?.height)
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
