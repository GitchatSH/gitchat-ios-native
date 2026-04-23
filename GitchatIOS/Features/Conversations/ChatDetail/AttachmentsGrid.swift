import SwiftUI

/// iMessage-style grid for image attachments. Renders 1 / 2 / 3 / 4+
/// layouts with a "+N" overlay on the fourth tile when attachments
/// count exceeds 4. Each tile is a `CachedAsyncImage` with a stable
/// placeholder so layout does not reflow on image load.
struct AttachmentsGrid: View {
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
    private func tile(_ a: MessageAttachment, width: CGFloat, height: CGFloat, overlay: String? = nil) -> some View {
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
                Rectangle()
                    .fill(Color.black.opacity(0.4))
                Text(overlay)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            if isUploading {
                Rectangle()
                    .fill(Color.black.opacity(0.25))
                AttachmentProgressOverlay()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onTap(urlStr) }
    }

    @ViewBuilder
    private func one(_ a: MessageAttachment) -> some View {
        // Aspect-aware single tile via CachedAsyncImage's fit fields.
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
                AttachmentProgressOverlay()
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
                tile(items[3], width: side, height: side, overlay: extra > 0 ? "+\(extra)" : nil)
            }
        }
    }
}

/// Circular ring rendered over an uploading attachment tile. Without
/// a real per-task progress value plumbed through, this shows an
/// indeterminate spinner variant (`.progressViewStyle(.circular)`).
/// When a `@Binding var fraction: Double` is threaded from the VM
/// the ring becomes determinate.
struct AttachmentProgressOverlay: View {
    var fraction: Double? = nil

    var body: some View {
        Group {
            if let fraction {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 3)
                        .frame(width: 38, height: 38)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0, min(1, fraction))))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 38, height: 38)
                        .rotationEffect(.degrees(-90))
                }
            } else {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            }
        }
    }
}
