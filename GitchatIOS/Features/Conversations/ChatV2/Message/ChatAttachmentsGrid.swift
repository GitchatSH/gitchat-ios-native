import SwiftUI

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

    private let spacing: CGFloat = 3
    private let corner: CGFloat = 14

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
        .onTapGesture { onTap(urlStr) }
    }

    @ViewBuilder
    private func one(_ a: MessageAttachment) -> some View {
        let url = URL(string: a.url)
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
        .onTapGesture { onTap(a.url) }
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
