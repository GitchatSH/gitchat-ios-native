import SwiftUI

/// Hosts the `MessageMenuOverlay` as a `ViewModifier`. Extracted so the
/// attachment point in `ChatDetailView.chatBody` stays a single
/// `.modifier(…)` call — keeps the outer body's modifier chain inside
/// Swift's expression type-check budget.
struct MessageMenuHostModifier: ViewModifier {
    @Binding var target: MessageMenuTarget?
    let auth: AuthStore
    @ObservedObject var vm: ChatViewModel
    let resolvedAvatar: String?
    let onQuickReact: (Message, String) -> Void
    let onMoreReactions: (Message) -> Void
    let actions: (Message) -> AnyView

    func body(content: Content) -> some View {
        content.overlay {
            if let t = target {
                MessageMenuOverlay(
                    target: t,
                    onDismiss: { target = nil },
                    onQuickReact: { emoji in onQuickReact(t.message, emoji) },
                    onMoreReactions: { onMoreReactions(t.message) },
                    preview: {
                        MessageBubble(
                            message: t.message,
                            isMe: t.isMe,
                            myLogin: auth.login,
                            resolvedAvatar: resolvedAvatar,
                            showHeader: true,
                            isPinned: vm.pinnedIds.contains(t.message.id)
                        )
                    },
                    actions: { actions(t.message) }
                )
                .zIndex(100)
                .transition(.opacity)
            }
        }
    }
}
