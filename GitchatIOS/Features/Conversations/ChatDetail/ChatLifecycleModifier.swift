import SwiftUI

/// Bundles the onChange / onReceive lifecycle hooks on `ChatDetailView`
/// into a single `.modifier(…)` call so the outer body's modifier chain
/// stays inside Swift's expression type-check budget.
struct ChatLifecycleModifier: ViewModifier {
    @ObservedObject var vm: ChatViewModel
    @Binding var scrollToBottomToken: Int
    let composerFocused: Bool
    let myLogin: String?
    let onConversationUpdated: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await vm.load() } }
            }
            .onChange(of: vm.messages.last?.id) { _ in
                // Whenever the latest message is one I just sent, force the
                // collection view to scroll to it — even if the user had
                // scrolled up before tapping send.
                guard let last = vm.messages.last, last.sender == myLogin else { return }
                scrollToBottomToken &+= 1
            }
            .onChange(of: composerFocused) { focused in
                // Focus → jump to latest so the keyboard doesn't cover
                // the conversation the user is replying into.
                if focused { scrollToBottomToken &+= 1 }
            }
            .onReceive(NotificationCenter.default.publisher(for: .gitchatConversationUpdated)) { _ in
                onConversationUpdated()
            }
    }
}
