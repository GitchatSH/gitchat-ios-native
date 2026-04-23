import SwiftUI

/// State carried across the long-press → overlay → dismiss lifecycle.
/// Created when a cell reports a long-press; nilled when the overlay
/// dismisses.
struct MessageMenuTarget: Identifiable, Equatable {
    let id = UUID()
    let message: Message
    let isMe: Bool
    /// Global frame of the source cell in screen coordinates. Drives
    /// the "fly up from here" transition.
    let sourceFrame: CGRect

    static func == (lhs: MessageMenuTarget, rhs: MessageMenuTarget) -> Bool {
        lhs.id == rhs.id
    }
}
