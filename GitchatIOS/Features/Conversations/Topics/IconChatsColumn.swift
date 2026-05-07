#if targetEnvironment(macCatalyst)
import SwiftUI

/// Catalyst-only narrow icon column rendered to the left of
/// `TopicListSidebarView` when the user is in topic mode. Shows all
/// conversations as 32pt avatars; tap routes via
/// `AppRouter.switchToConversation(_:)`.
///
/// Lives inside the sidebar's pushed `navigationDestination` HStack.
struct IconChatsColumn: View {
    let activeParentId: String

    @StateObject private var vm = ConversationsViewModel()
    @StateObject private var router = AppRouter.shared

    private var conversations: [Conversation] {
        vm.conversations.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return (a.last_message_at ?? "") > (b.last_message_at ?? "")
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(conversations) { convo in
                    iconRow(for: convo)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
        .task { await vm.load() }
    }

    @ViewBuilder
    private func iconRow(for convo: Conversation) -> some View {
        let isActive = convo.id == activeParentId
        let unread = vm.locallyRead.contains(convo.id) ? 0 : convo.unreadCount

        VStack(spacing: 2) {
            ZStack {
                if isActive {
                    Circle()
                        .fill(Color("AccentColor").opacity(0.25))
                        .frame(width: 52, height: 52)
                }
                if convo.isGroup {
                    GroupAvatarView(
                        name: convo.group_name ?? convo.displayTitle,
                        avatarURL: convo.group_avatar_url,
                        groupId: convo.id,
                        size: 44
                    )
                } else {
                    AvatarView(
                        url: convo.displayAvatarURL,
                        size: 44,
                        login: convo.other_user?.login
                    )
                }
            }
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Color("AccentColor"), in: Capsule())
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.18), value: isActive)
        .contentShape(Rectangle())
        .onTapGesture {
            router.switchToConversation(convo)
        }
        .macHover()
        .accessibilityLabel(convo.displayTitle)
    }
}
#endif
