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

    private init() {}

    func openConversation(id: String, messageId: String? = nil) {
        selectedTab = 0
        pendingMessageId = messageId
        pendingConversationId = id
    }

    func openProfile(login: String) {
        pendingProfileLogin = login
    }
}
