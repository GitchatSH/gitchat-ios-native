import SwiftUI

struct TopicRow: View {
    let topic: Topic
    let isActive: Bool
    let isPinned: Bool
    let onTap: () -> Void

    init(topic: Topic, isActive: Bool, isPinned: Bool = false, onTap: @escaping () -> Void) {
        self.topic = topic
        self.isActive = isActive
        self.isPinned = isPinned
        self.onTap = onTap
    }

    @ScaledMetric(relativeTo: .caption) private var mentionBadgeSize: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var badgeMinSize: CGFloat = 18

    /// 44pt on Catalyst (Apple list standard), 64pt on iOS for the
    /// Telegram-feeling chat-list look — mirrors `ConversationRow`.
    private var iconSize: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 44
        #else
        return 64
        #endif
    }

    private var iconCornerRadius: CGFloat { iconSize * 0.25 }

    private var color: Color { TopicColorToken.resolve(topic.color_token).color }

    private var primaryTextColor: Color { isActive ? .white : .primary }
    private var secondaryTextColor: Color { isActive ? .white.opacity(0.85) : .secondary }
    private var tertiaryTextColor: Color { isActive ? .white.opacity(0.7) : .secondary }

    private var senderPreview: String? {
        guard let preview = topic.last_message_preview else { return nil }
        if let sender = topic.last_sender_login, !sender.isEmpty {
            return "\(sender): \(preview)"
        }
        return preview
    }

    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 12) {
            iconSquare
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.name)
                    .font(.headline)
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)
                if let preview = senderPreview {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let ts = topic.last_message_at {
                    Text(RelativeTime.chatListStamp(ts))
                        .font(.footnote)
                        .foregroundStyle(tertiaryTextColor)
                }
                badges
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(activeBackground)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: isActive)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .contentShape(Rectangle())
        .onTapGesture {
            #if !targetEnvironment(macCatalyst)
            Haptics.selection()
            #endif
            onTap()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityElement(children: .combine)
    }

    private var iconSquare: some View {
        Text(topic.displayEmoji)
            .font(.system(size: iconSize * 0.5))
            .frame(width: iconSize, height: iconSize)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: iconCornerRadius))
    }

    /// Mirrors the chats list's `rowBackground(for:)` pattern in
    /// `ConversationsListView` — a continuous-rounded inset pill rather
    /// than a flat full-width fill, so the active state visually matches
    /// the outer chats list.
    @ViewBuilder
    private var activeBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isActive ? Color("AccentColor") : Color.clear)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if topic.unread_count > 0 {
                if topic.hasMention {
                    Text("@")
                        .font(.caption.bold())
                        .frame(width: mentionBadgeSize, height: mentionBadgeSize)
                        .background(badgeBG, in: Circle())
                        .foregroundStyle(badgeFG)
                }
                if topic.hasReaction {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .frame(width: mentionBadgeSize, height: mentionBadgeSize)
                        .background(badgeBG, in: Circle())
                        .foregroundStyle(badgeFG)
                        .accessibilityLabel("reaction")
                }
                Text(topic.unread_count > 99 ? "99+" : "\(topic.unread_count)")
                    .font(.footnote.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .frame(minWidth: badgeMinSize, minHeight: badgeMinSize)
                    .background(badgeBG, in: .capsule)
                    .foregroundStyle(badgeFG)
            }
        }
    }

    private var badgeBG: Color {
        isActive ? .white : Color("AccentColor")
    }

    private var badgeFG: Color {
        isActive ? Color("AccentColor") : .white
    }
}

#if DEBUG
extension Topic {
    static func fixturePreview(id: String, name: String, emoji: String?,
                                color: String? = "blue", unread: Int = 0,
                                mentions: Int = 0, reactions: Int = 0,
                                isPinned: Bool = false) -> Topic {
        Topic(id: id, parent_conversation_id: "p", name: name, icon_emoji: emoji,
              color_token: color, is_general: id == "g",
              pin_order: isPinned ? 1 : nil, archived_at: nil,
              last_message_at: "2026-04-28T10:00:00Z",
              last_message_preview: "preview text", last_sender_login: "alice",
              unread_count: unread, unread_mentions_count: mentions,
              unread_reactions_count: reactions,
              created_by: "alice", created_at: "2026-04-20T08:00:00Z")
    }
}

#Preview {
    VStack(spacing: 0) {
        TopicRow(topic: .fixturePreview(id: "g", name: "General", emoji: "💬",
                                         unread: 0, isPinned: true),
                 isActive: true, isPinned: true, onTap: {})
        TopicRow(topic: .fixturePreview(id: "b", name: "Bugs", emoji: "🐛",
                                         unread: 12, mentions: 1, isPinned: true),
                 isActive: false, isPinned: true, onTap: {})
        TopicRow(topic: .fixturePreview(id: "v", name: "v2.0", emoji: "🚀",
                                         color: "red", unread: 1),
                 isActive: false, isPinned: false, onTap: {})
    }
}
#endif
