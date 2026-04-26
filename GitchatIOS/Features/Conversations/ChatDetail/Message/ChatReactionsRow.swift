import SwiftUI

/// Horizontal row of reaction chips rendered under a message bubble.
/// Each chip shows emoji + count; the current user's reactions get a
/// tinted background + accent bordered pill.
///
/// - Tap pill → toggle react/unreact (spec Feature 9)
/// - Long-press pill → open emoji picker
/// - Max 5 emoji types displayed; extras collapsed to "+N" pill
struct ChatReactionsRow: View {
    let reactions: [MessageReaction]
    let myLogin: String?
    /// Pre-computed set of emojis the current user has reacted with.
    let myReactionEmojis: Set<String>
    /// Tap a pill → toggle that emoji reaction.
    let onToggleReact: (String) -> Void
    /// Long-press a pill → open full emoji picker.
    let onLongPress: () -> Void
    /// Tap the row in general (e.g. open reactors sheet).
    let onTap: () -> Void

    private let maxVisible = 5

    var body: some View {
        HStack(spacing: 4) {
            let visible = reactions.count <= maxVisible
                ? reactions
                : Array(reactions.prefix(maxVisible - 1))
            ForEach(visible, id: \.emoji) { r in
                chip(r)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            if reactions.count > maxVisible {
                let extra = reactions.count - (maxVisible - 1)
                Text("+\(extra)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(minHeight: 28)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(
                            Color(.separator), lineWidth: 1
                        )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .highPriorityGesture(TapGesture().onEnded { onTap() })
            }
        }
        .animation(
            .spring(response: 0.35, dampingFraction: 0.55),
            value: reactions
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
            .font(.caption2.weight(.semibold))
            .foregroundStyle(mine ? Color("AccentColor") : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(minHeight: 28)
            .background(
                mine
                    ? Color("AccentColor").opacity(0.08)
                    : Color(.systemBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(
                    mine ? Color("AccentColor") : Color(.separator),
                    lineWidth: 1
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .highPriorityGesture(TapGesture().onEnded { onToggleReact(r.emoji) })
            .onLongPressGesture { onLongPress() }
            .instantTooltip(mine ? "You reacted \(r.emoji)" : "\(r.count) reaction\(r.count == 1 ? "" : "s")")
    }
}
