import SwiftUI

/// Horizontal row of reaction chips rendered under a message bubble.
/// Each chip shows emoji + count; the current user's reactions get a
/// tinted background + bordered capsule. Tap opens the reactors
/// sheet.
struct ChatReactionsRow: View {
    @Environment(\.chatTheme) private var theme

    let reactions: [MessageReaction]
    let myLogin: String?
    /// Pre-computed set of emojis the current user has reacted with —
    /// cheaper than checking `reactionRows` per chip during render.
    let myReactionEmojis: Set<String>
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.emoji) { r in
                chip(r)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .animation(
            .spring(response: 0.35, dampingFraction: 0.55),
            value: reactions.map { "\($0.emoji)|\($0.count)" }
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private func chip(_ r: MessageReaction) -> some View {
        let mine = myReactionEmojis.contains(r.emoji)
        let label = Group {
            if #available(iOS 17.0, *) {
                Text("\(r.emoji) \(r.count)")
                    .contentTransition(.numericText(value: Double(r.count)))
            } else {
                Text("\(r.emoji) \(r.count)")
            }
        }
        label
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                mine
                    ? AnyShapeStyle(theme.replyAccent.opacity(0.25))
                    : AnyShapeStyle(.ultraThinMaterial)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    mine ? theme.replyAccent.opacity(0.6) : Color.clear,
                    lineWidth: 1
                )
            )
            .instantTooltip(mine ? "You reacted \(r.emoji)" : "\(r.count) reaction\(r.count == 1 ? "" : "s")")
    }
}
