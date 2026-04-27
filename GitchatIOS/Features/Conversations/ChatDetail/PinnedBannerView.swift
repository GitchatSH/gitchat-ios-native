import SwiftUI

/// Telegram-style pinned message banner: rounded pill with multi-segment
/// indicator left, title + preview, list icon right. Floats below nav header.
struct PinnedBannerView: View {
    let pinnedMessages: [Message]
    let onTap: (Message) -> Void
    let onShowList: () -> Void
    @State private var currentIndex = 0

    var body: some View {
        if let msg = pinnedMessages[safe: currentIndex] ?? pinnedMessages.first {
            HStack(spacing: 0) {
                // Indicator bar left
                PinnedIndicatorBar(
                    totalCount: pinnedMessages.count,
                    currentIndex: currentIndex
                )
                .padding(.vertical, 8)
                .padding(.leading, 12)

                // Title + preview
                VStack(alignment: .leading, spacing: 1) {
                    Text(pinnedMessages.count > 1
                         ? "Pinned Message #\(currentIndex + 1)"
                         : "Pinned Message")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color("AccentColor"))
                    Text(msg.content)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if pinnedMessages.count > 1 {
                        let nextIndex = (currentIndex + 1) % pinnedMessages.count
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            currentIndex = nextIndex
                        }
                    }
                    onTap(msg)
                }

                // List icon
                Button {
                    onShowList()
                } label: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 44)
            .modifier(GlassPill())
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .onChange(of: pinnedMessages.count) { newCount in
                if currentIndex >= newCount {
                    currentIndex = max(0, newCount - 1)
                }
            }
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
