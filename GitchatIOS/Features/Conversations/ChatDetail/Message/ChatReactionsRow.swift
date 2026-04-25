import SwiftUI

/// Horizontal row of reaction chips rendered under a message bubble.
/// Each chip shows emoji + count; the current user's reactions get a
/// tinted background + bordered capsule. Tap opens the reactors
/// sheet.
struct ChatReactionsRow: View {
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
            .font(.footnote)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(minHeight: 44)
            .background(
                mine
                    ? Color("AccentColor").opacity(0.08)
                    : Color(.systemBackground)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    mine ? Color("AccentColor") : Color(.separator),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
            .highPriorityGesture(TapGesture().onEnded { onTap() })
            .instantTooltip(mine ? "You reacted \(r.emoji)" : "\(r.count) reaction\(r.count == 1 ? "" : "s")")
    }
}
