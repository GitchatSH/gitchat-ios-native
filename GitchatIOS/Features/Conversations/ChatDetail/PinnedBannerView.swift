import SwiftUI

/// Telegram-style pinned message banner: rounded pill with accent bar left,
/// title + preview, unpin icon right. Floats below nav header.
struct PinnedBannerView: View {
    let pinnedMessages: [Message]
    let onTap: (Message) -> Void
    let onShowList: () -> Void
    @State private var currentIndex = 0

    var body: some View {
        if let msg = pinnedMessages[safe: currentIndex] ?? pinnedMessages.first {
            HStack(spacing: 0) {
                // Accent bar left
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color("AccentColor"))
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 12)

                // Title + preview
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pinned Message")
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
                        withAnimation(.easeInOut(duration: 0.15)) {
                            currentIndex = (currentIndex + 1) % pinnedMessages.count
                        }
                    }
                    onTap(msg)
                }

                // Unpin / list icon
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
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
