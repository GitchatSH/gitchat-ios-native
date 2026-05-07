import SwiftUI

#if targetEnvironment(macCatalyst)

/// Catalyst-only root shell. Wraps a single `NavigationSplitView`:
/// the sidebar swaps content based on the active tab, the detail
/// panel always shows the selected chat (or a placeholder).
///
/// This is the Telegram Desktop pattern — switching tabs changes
/// the sidebar, never the chat being read.
struct MacShellView: View {
    @StateObject private var router = AppRouter.shared

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebarContainer
                .applyMacSidebarWidth()
        } detail: {
            NavigationStack {
                detailPanel
            }
            .id(detailIdentity)
            .onReceive(TopicListStore.shared.objectWillChange) { _ in
                guard let active = router.selectedTopic else { return }
                let topics = TopicListStore.shared.topics(forParent: active.parent.id)
                if !topics.contains(where: { $0.id == active.topic.id }) {
                    ToastCenter.shared.show(.info, "Topic archived",
                                            "It was archived by another member")
                    router.exitTopicMode()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(macTabShortcuts)
        .background(escapeKeyHandler)
    }

    /// Identity for the detail column's NavigationStack. Changing this
    /// on tab-switch tears the stack down so any view a sidebar
    /// NavigationLink pushed (e.g. a profile from Discover) is cleared
    /// along with it. Also keyed on the selected conversation so picking
    /// a new chat refreshes the root content.
    private var detailIdentity: String {
        let tab = router.selectedTab
        let convoId = router.selectedConversation?.id ?? "none"
        let profile = router.selectedProfile ?? "none"
        // Note: topic switches don't go into the identity here — the inner
        // ChatDetailView in detailPanel has its own .id("topic-...") that
        // rebuilds per-topic without tearing down the surrounding stack.
        // Letting this identity bypass topic changes lets the .transition
        // on the detail Group fire (move + opacity) on topic switches.
        return "tab-\(tab)-profile-\(profile)-convo-\(convoId)"
    }

    @ViewBuilder
    private var sidebarContainer: some View {
        currentTabSidebar
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MacBottomNav(
                    selectedTab: Binding(
                        get: { router.selectedTab },
                        set: { router.selectedTab = $0 }
                    ),
                    unreadChats: 0,
                    unreadActivity: 0
                )
            }
    }

    @ViewBuilder
    private var currentTabSidebar: some View {
        switch router.selectedTab {
        case 0:
            NavigationStack(path: Binding(
                get: { router.topicSidebarPath },
                set: { router.topicSidebarPath = $0 }
            )) {
                ConversationsListView()
                    .navigationDestination(for: TopicSidebarRoute.self) { route in
                        HStack(spacing: 0) {
                            IconChatsColumn(activeParentId: route.parent.id)
                                .frame(width: 60)
                            Divider()
                            TopicListSidebarView(parent: route.parent)
                        }
                    }
            }
        case 1: DiscoverView()
        case 2: NotificationsView()
        case 3: FollowingView()
        case 4: MeView()
        default: EmptyView()
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        Group {
            if let login = router.selectedProfile {
                ProfileView(login: login)
            } else if let target = router.selectedTopic {
                ChatDetailView(conversation: target.parent, initialTopic: target.topic)
                    .id("topic-\(target.topic.id)")
            } else if let convo = router.selectedConversation {
                ChatDetailView(conversation: convo)
            } else {
                ContentUnavailableCompat(
                    title: "Select a conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: "Pick a chat from the sidebar to start reading."
                )
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    /// Hidden buttons that bind ⌘1–⌘5 to tab indices.
    @ViewBuilder
    private var macTabShortcuts: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { idx in
                Button("") { router.selectedTab = idx }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                    .hidden()
            }
        }
    }

    /// Escape drops the detail panel back to its placeholder — clears
    /// any previewed profile first, then the selected conversation, so
    /// a single press always matches what the user "backs out" of.
    @ViewBuilder
    private var escapeKeyHandler: some View {
        Button("") {
            if router.selectedProfile != nil {
                router.selectedProfile = nil
            } else {
                router.selectedConversation = nil
            }
        }
        .keyboardShortcut(.escape, modifiers: [])
        .hidden()
    }
}

private extension View {
    @ViewBuilder
    func applyMacSidebarWidth() -> some View {
        if #available(iOS 17.0, *) {
            self.navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                .toolbar(removing: .sidebarToggle)
        } else {
            self.navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        }
    }
}

#endif
