import SwiftUI

/// Horizontal row of reaction chips rendered under a message bubble.
/// Each chip shows emoji + avatar stack (≤3) or count (>3).
///
/// - Tap pill → toggle react/unreact
/// - Long-press pill → open emoji picker
/// - Max 5 emoji types displayed; extras collapsed to "+N" pill
struct ChatReactionsRow: View {
    let reactions: [MessageReaction]
    let reactionRows: [RawReactionRow]
    let myLogin: String?
    /// Pre-computed set of emojis the current user has reacted with.
    let myReactionEmojis: Set<String>
    /// Whether this is inside an outgoing (my) bubble.
    var isOutgoing: Bool = false
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
                    .background(Color("AccentColor").opacity(0.20))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .highPriorityGesture(TapGesture().onEnded { onTap() })
            }
        }
        .animation(
            .spring(response: 0.35, dampingFraction: 0.55),
            value: reactions
        )
    }

    /// Logins who reacted with this emoji.
    private func loginsFor(_ emoji: String) -> [String] {
        reactionRows
            .filter { $0.emoji == emoji }
            .compactMap(\.user_login)
    }

    @ViewBuilder
    private func chip(_ r: MessageReaction) -> some View {
        let mine = myReactionEmojis.contains(r.emoji)
        let logins = loginsFor(r.emoji)

        // Incoming: mine=accent, others=accent subtle
        // Outgoing: mine=white, others=white 20%
        let chipBg: Color = {
            if isOutgoing {
                return mine ? .white : .white.opacity(0.2)
            } else {
                return mine ? Color("AccentColor") : Color.primary.opacity(0.05)
            }
        }()
        let chipFg: Color = {
            if isOutgoing {
                return mine ? Color("AccentColor") : .white.opacity(0.85)
            } else {
                return mine ? .white : .primary
            }
        }()

        HStack(spacing: 4) {
            Text(r.emoji)
            if r.count <= 3 && !logins.isEmpty {
                // Avatar stack for ≤3 reactors
                avatarStack(logins: logins)
            } else {
                // Count for >3
                if #available(iOS 17.0, *) {
                    Text("\(r.count)")
                        .contentTransition(.numericText(value: Double(r.count)))
                } else {
                    Text("\(r.count)")
                }
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(chipFg)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(chipBg)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .highPriorityGesture(TapGesture().onEnded { onToggleReact(r.emoji) })
        .onLongPressGesture { onLongPress() }
        .instantTooltip(mine ? "You reacted \(r.emoji)" : "\(r.count) reaction\(r.count == 1 ? "" : "s")")
    }

    @ViewBuilder
    private func avatarStack(logins: [String]) -> some View {
        HStack(spacing: -6) {
            ForEach(logins.prefix(3), id: \.self) { login in
                AsyncImage(url: URL(string: "https://github.com/\(login).png")) { image in
                    image.resizable()
                } placeholder: {
                    Circle().fill(Color(.tertiarySystemFill))
                }
                .frame(width: 14, height: 14)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.clear, lineWidth: 0.5))
            }
        }
    }
}
