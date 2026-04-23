import SwiftUI

/// Shared global router used for external-navigation events like push
/// notification taps.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    /// Which root tab is selected.
    @Published var selectedTab: Int = 0

    /// Pending conversation id to push onto the Chats tab on next tick.
    @Published var pendingConversationId: String?

    /// Optional pending target message id — set alongside
    /// `pendingConversationId` so the chat detail can jump + pulse it.
    @Published var pendingMessageId: String?

    /// Pending profile login to present as a sheet on next tick.
    @Published var pendingProfileLogin: String?

    /// Pending group invite code consumed by the root view to present
    /// `InvitePreviewSheet`. Set from the `gitchat://invite/<code>`
    /// deep-link handler.
    @Published var pendingInviteCode: String?

    private init() {}

    /// Route a `gitchat://` URL opened via `.onOpenURL`. Returns `true`
    /// if the URL was recognized, so callers can skip the fallback
    /// (Facebook SDK) delegate.
    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme == "gitchat" else { return false }
        // Accepts both `gitchat://invite/<code>` and the host-form
        // `gitchat:invite/<code>` — iOS parses the former with host="invite"
        // and a leading-slash path, the latter with the full path.
        let parts = ([url.host].compactMap { $0 } + url.pathComponents)
            .filter { !$0.isEmpty && $0 != "/" }
        guard parts.count >= 2, parts[0] == "invite" else { return false }
        pendingInviteCode = parts[1]
        return true
    }

    func openConversation(id: String, messageId: String? = nil) {
        selectedTab = 0
        pendingMessageId = messageId
        pendingConversationId = id
    }

    func openProfile(login: String) {
        pendingProfileLogin = login
    }
}
