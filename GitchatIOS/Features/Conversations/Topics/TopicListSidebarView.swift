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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button {
                    router.exitTopicMode()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color("AccentColor"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to chats")

                Text("💬")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color("AccentColor").opacity(0.15))
                    )

                Text(parent.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color("AccentColor"))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .macHover()
                .accessibilityLabel("New Topic")
            }

            Text(memberSubtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 36)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
#endif
