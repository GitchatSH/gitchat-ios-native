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
            guard parts.count >= 2, parts[0] == "invite" else { return false }
            pendingInviteCode = parts[1]
            return true

        case "https":
            guard let host = url.host?.lowercased(),
                  host == "gitchat.sh" || host.hasSuffix(".gitchat.sh") else {
                return false
            }
            // parts[0] is the host — find the "invite" segment explicitly.
            let path = url.pathComponents.filter { !$0.isEmpty && $0 != "/" }
            guard path.count >= 2, path[0] == "invite" else { return false }
            pendingInviteCode = path[1]
            return true

        default:
            return false
        }
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
