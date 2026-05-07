#if targetEnvironment(macCatalyst)
import SwiftUI

/// Catalyst-only wrapper around `TopicListContent`. Renders the 2-line
/// sidebar header (back · group emoji · group name · "+" / "N members ·
/// M online") and the topic list body. Hosted via the sidebar's
/// `NavigationStack` in `MacShellView` and pushed when the user clicks
/// a topic-enabled group in the chats list.
struct TopicListSidebarView: View {
    let parent: Conversation

    @StateObject private var router = AppRouter.shared
    @ObservedObject private var presence = PresenceStore.shared
    @State private var showCreate = false

    private var memberSubtitle: String {
        let participants = parent.participantsOrEmpty.map(\.login)
        if participants.isEmpty {
            return "Members"
        }
        let onlineCount = participants.filter { presence.isOnline($0) }.count
        if onlineCount > 0 {
            return "\(participants.count) members · \(onlineCount) online"
        }
        return "\(participants.count) members"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TopicListContent(
                parent: parent,
                activeTopicId: router.selectedTopic?.topic.id,
                showCreate: $showCreate,
                onPickTopic: { picked in
                    router.pickTopic(picked, in: parent)
                }
            )
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showCreate) {
            TopicCreateSheet(parent: parent) { newTopic in
                TopicListStore.shared.append(newTopic, parentId: parent.id)
            }
        }
        .task {
            // PresenceStore is reactive; ensure presence subscriptions
            // are warmed up for everyone in this parent group so the
            // online-count subtitle stays accurate.
            presence.ensure(parent.participantsOrEmpty.map(\.login))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // Leading back chevron
            Button {
                router.exitTopicMode()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color("AccentColor"))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to chats")

            // Parent group avatar — same component as ConversationRow uses
            if parent.isGroup {
                GroupAvatarView(
                    name: parent.group_name ?? parent.displayTitle,
                    avatarURL: parent.group_avatar_url,
                    groupId: parent.id,
                    size: 44
                )
            } else {
                AvatarView(
                    url: parent.displayAvatarURL,
                    size: 44,
                    login: parent.other_user?.login
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(parent.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(memberSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                showCreate = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color("AccentColor"))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .macHover()
            .accessibilityLabel("New Topic")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 60)  // match ConversationRow height
        .background(Color("AccentColor").opacity(0.08))
    }
}
#endif
