import SwiftUI

/// Sidebar `NavigationStack` route used on Mac Catalyst when the user
/// enters topic mode for a parent group conversation.
struct TopicSidebarRoute: Hashable {
    let parent: Conversation
}

/// Route used on iOS to push a topic chat from the topic list view.
struct TopicChatRoute: Hashable {
    let topic: Topic
    let parent: Conversation
}

/// Active topic target. Wraps the (topic, parent) pair so SwiftUI can
/// diff the detail panel cleanly.
struct TopicTarget: Equatable {
    let topic: Topic
    let parent: Conversation
}

/// Shared global router used for external-navigation events like push
/// notification taps.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    /// Which root tab is selected.
    @Published var selectedTab: Int = 0 {
        didSet {
            // Profile browsing is transient — clear it whenever the user
            // jumps to a different tab so the detail panel snaps back to
            // the sticky chat (or placeholder) for that context.
            if oldValue != selectedTab { selectedProfile = nil }
            // Topic mode is bound to the Chats tab. Leaving Chats resets
            // the topic sidebar stack so returning lands on chats list.
            if oldValue != selectedTab && oldValue == 0 {
                topicSidebarPath = NavigationPath()
                selectedTopic = nil
            }
        }
    }

    /// Conversation currently shown in the Catalyst split-view detail
    /// panel. Persists across tab switches so opening Discover/Activity
    /// doesn't blank the chat the user was reading.
    @Published var selectedConversation: Conversation? = nil {
        didSet {
            // Picking a new chat means "show me this conversation" —
            // drop any profile we were previewing so the chat actually
            // appears in the detail panel.
            if selectedConversation != nil { selectedProfile = nil }
        }
    }

    /// Profile login currently previewed in the Catalyst detail panel.
    /// Takes priority over `selectedConversation` while set; cleared on
    /// tab switch or when a conversation is picked.
    @Published var selectedProfile: String? = nil

    /// Pending conversation id to push onto the Chats tab on next tick.
    @Published var pendingConversationId: String?

    /// Optional pending target message id — set alongside
    /// `pendingConversationId` so the chat detail can jump + pulse it.
    @Published var pendingMessageId: String?
    /// Hint for fast cursor-jump when navigating to a search result.
    @Published var pendingMessageCreatedAt: String?

    /// Pending profile login to present as a sheet on next tick.
    @Published var pendingProfileLogin: String?

    /// Pending group invite code consumed by the root view to present
    /// `InvitePreviewSheet`. Set from the `gitchat://invite/<code>`
    /// deep-link handler.
    @Published var pendingInviteCode: String?

    /// Catalyst sidebar `NavigationStack` path. Empty = chats list shown.
    /// One element = topic list pushed for that parent.
    @Published var topicSidebarPath: NavigationPath = NavigationPath()

    /// What the Catalyst detail panel renders while the user is in topic
    /// mode. `nil` = fall back to placeholder / `selectedConversation`.
    @Published var selectedTopic: TopicTarget? = nil {
        didSet {
            // Picking a topic clears any sticky chat / profile preview so
            // the detail panel actually displays the topic chat.
            if selectedTopic != nil {
                selectedConversation = nil
                selectedProfile = nil
            }
        }
    }

    /// In-memory dict of last-picked topic per parent for the current
    /// session. Not persisted across launches.
    private(set) var activeTopicByParent: [String: String] = [:]

    private init() {}

    /// Route a Gitchat deep link. Accepts both our custom scheme
    /// (`gitchat://invite/<code>`) and https URLs that point at our web
    /// host (`https://{dev.,}gitchat.sh/invite/<code>`) — the latter so
    /// in-app taps on a shared invite URL route to `InvitePreviewSheet`
    /// instead of opening Safari and hitting a 404 while BE/AASA is
    /// still being set up.
    ///
    /// Returns `true` when recognized so callers can skip the fallback
    /// handler (Facebook SDK for scheme URLs, SafariSheet for https).
    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        // Path form works for both schemes — gather everything after
        // the host/scheme into an ordered list of non-empty segments.
        let parts = (([url.host].compactMap { $0 }) + url.pathComponents)
            .filter { !$0.isEmpty && $0 != "/" }

        switch url.scheme?.lowercased() {
        case "gitchat":
            if let code = inviteCode(fromSegments: parts) {
                pendingInviteCode = code
                return true
            }
            return false

        case "https":
            guard let host = url.host?.lowercased(),
                  host == "gitchat.sh" || host.hasSuffix(".gitchat.sh") else {
                return false
            }
            let path = url.pathComponents.filter { !$0.isEmpty && $0 != "/" }
            if let code = inviteCode(fromSegments: path) {
                pendingInviteCode = code
                return true
            }
            return false

        default:
            return false
        }
    }

    /// Look for any `invite` or `join` segment followed by a non-empty
    /// code. Accepts a range of shapes BE might pick:
    /// `/invite/<code>`, `/join/<code>`, `/messages/conversations/join/<code>`.
    private func inviteCode(fromSegments segs: [String]) -> String? {
        guard let markerIdx = segs.firstIndex(where: {
            let s = $0.lowercased()
            return s == "invite" || s == "join"
        }) else { return nil }
        let codeIdx = segs.index(after: markerIdx)
        guard segs.indices.contains(codeIdx) else { return nil }
        let code = segs[codeIdx]
        return code.isEmpty ? nil : code
    }

    func openConversation(id: String, messageId: String? = nil) {
        selectedTab = 0
        pendingMessageId = messageId
        pendingConversationId = id
    }

    func openProfile(login: String) {
        pendingProfileLogin = login
    }

    /// Pushes the topic list onto the Catalyst sidebar stack and resolves
    /// a default active topic. Call from row tap on a topic-enabled group.
    func enterTopicMode(parent: Conversation) {
        topicSidebarPath.append(TopicSidebarRoute(parent: parent))
        if let resolved = resolveActiveTopic(parent: parent) {
            selectedTopic = TopicTarget(topic: resolved, parent: parent)
        } else {
            selectedTopic = nil   // empty list — detail panel shows placeholder
        }
    }

    /// Records and renders the user's pick. Idempotent.
    func pickTopic(_ topic: Topic, in parent: Conversation) {
        activeTopicByParent[parent.id] = topic.id
        selectedTopic = TopicTarget(topic: topic, parent: parent)
    }

    /// Pops the sidebar back to the chats list and clears the active
    /// topic. Detail panel snaps to the placeholder.
    func exitTopicMode() {
        topicSidebarPath = NavigationPath()
        selectedTopic = nil
    }

    /// Returns the topic that should be rendered when entering topic mode.
    /// Order: previously-picked → general → first.
    private func resolveActiveTopic(parent: Conversation) -> Topic? {
        let topics = TopicListStore.shared.topics(forParent: parent.id)
        if let id = activeTopicByParent[parent.id],
           let t = topics.first(where: { $0.id == id }) {
            return t
        }
        if let general = topics.first(where: { $0.is_general }) {
            return general
        }
        return topics.first
    }

    /// Picks a chats-list conversation while the user is in topic mode.
    /// Forum groups swap topic list; non-forum chats exit topic mode.
    func switchToConversation(_ convo: Conversation) {
        // Same-target tap: no-op to avoid flicker.
        if convo.hasTopicsEnabled, selectedTopic?.parent.id == convo.id {
            return
        }
        if !convo.hasTopicsEnabled, selectedConversation?.id == convo.id, selectedTopic == nil {
            return
        }

        if convo.hasTopicsEnabled {
            // Reset path then re-enter topic mode for the new parent.
            // Single-element invariant per topicSidebarPath doc-comment.
            topicSidebarPath = NavigationPath()
            enterTopicMode(parent: convo)
        } else {
            exitTopicMode()
            selectedConversation = convo
        }
    }
}
