import SwiftUI
import UIKit

/// Horizontal capsule with 8 quick emojis + a "more" chevron. Sits
/// above the preview bubble inside `MessageMenuOverlay`. Emojis the
/// current user has already reacted with render inside a filled
/// circle to signal "you reacted with this" (exyte-style).
struct ReactionSelectionView: View {
    @Environment(\.chatTheme) private var theme

    /// Emojis the current user has already reacted with. Highlighted
    /// in the pill so a second tap feels like un-picking (parity
    /// with iMessage).
    let currentReactions: Set<String>
    let onPick: (String) -> Void
    let onMore: () -> Void

    static let quick: [String] = ["❤️", "👍", "😂", "🔥", "🎉", "👀", "🙏", "😢"]

    private let bubbleDiameter: CGFloat = 38
    private let horizontalInset: CGFloat = 12
    private let verticalInset: CGFloat = 6

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.quick, id: \.self) { emoji in
                emojiButton(emoji)
            }
            moreButton()
        }
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, verticalInset)
        .background(
            Capsule(style: .continuous).fill(theme.reactionPickerBg)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(theme.menuDivider.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
    }

    @ViewBuilder
    private func emojiButton(_ emoji: String) -> some View {
        let isSelected = currentReactions.contains(emoji)
        Button { onPick(emoji) } label: {
            EmojiLabel(text: emoji, pointSize: 26)
                .frame(width: bubbleDiameter, height: bubbleDiameter)
                .background(
                    Group {
                        if isSelected {
                            Circle()
                                .fill(theme.reactionPickerSelectedBg)
                        } else {
                            Color.clear
                        }
                    }
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func moreButton() -> some View {
        Button(action: onMore) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: bubbleDiameter)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// UIKit-backed emoji label. SwiftUI's `Text(emoji).font(.system(...))`
/// inherits whatever font the enclosing view set (our app registers a
/// custom body font globally), and emoji fall back to question-mark
/// squares when the inherited font has no emoji coverage. Using
/// `UILabel` with `UIFont.systemFont(ofSize:)` always goes through
/// UIKit's emoji cascade (AppleColorEmoji) and renders correctly.
private struct EmojiLabel: UIViewRepresentable {
    let text: String
    let pointSize: CGFloat

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: pointSize)
        label.text = text
        label.adjustsFontForContentSizeCategory = false
        label.backgroundColor = .clear
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.font = UIFont.systemFont(ofSize: pointSize)
    }
}
