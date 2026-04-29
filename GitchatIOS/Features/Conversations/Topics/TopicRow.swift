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

    private var color: Color { TopicColorToken.resolve(topic.color_token).color }

    var body: some View {
        HStack(spacing: 12) {
            iconSquare
            VStack(alignment: .leading, spacing: 2) {
                Text("\(topic.displayEmoji) \(topic.name)")
                    .font(.headline).foregroundStyle(.primary)
                    .lineLimit(1)
                if let preview = topic.last_message_preview {
                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("pinned")
                    }
                    if let ts = topic.last_message_at {
                        Text(RelativeTime.chatListStamp(ts)).font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                badges
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(isActive ? Color("AccentColor").opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
    }

    private var iconSquare: some View {
        Text(topic.displayEmoji)
            .font(.title3)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if topic.unread_count > 0 {
                if topic.hasMention {
                    Text("@").font(.caption.bold())
                        .frame(width: mentionBadgeSize, height: mentionBadgeSize)
                        .background(Color("AccentColor"), in: Circle())
                        .foregroundStyle(.white)
                }
                if topic.hasReaction {
                    Image(systemName: "heart.fill").font(.system(size: 10))
                        .frame(width: mentionBadgeSize, height: mentionBadgeSize)
                        .background(Color("AccentColor"), in: Circle())
                        .foregroundStyle(.white)
                        .accessibilityLabel("reaction")
                }
                Text(topic.unread_count > 99 ? "99+" : "\(topic.unread_count)")
                    .font(.footnote.bold())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .frame(minWidth: badgeMinSize, minHeight: badgeMinSize)
                    .background(Color("AccentColor"), in: .capsule)
                    .foregroundStyle(.white)
            }
        }
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
