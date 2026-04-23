import SwiftUI

/// Horizontal pill with 8 quick emojis + a "more" chevron. Sits above
/// the preview bubble in the message menu overlay.
struct ReactionPickerBar: View {
    static let quick: [String] = ["❤️", "👍", "😂", "🔥", "🎉", "👀", "🙏", "😢"]

    let onPick: (String) -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.quick, id: \.self) { emoji in
                Button { onPick(emoji) } label: {
                    Text(emoji).font(.system(size: 26))
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            Button(action: onMore) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 38)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(.separator).opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
    }
}
