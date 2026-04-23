import SwiftUI

/// State passed from the UIKit long-press gesture (on the messages
/// list's underlying `UICollectionView` / `UITableView`) into the
/// SwiftUI `MessageMenu` overlay. `sourceFrame` is the cell's frame
/// in screen coordinates; it drives the "fly up" transition.
struct MessageMenuTarget: Identifiable, Equatable {
    let id = UUID()
    let message: Message
    let isMe: Bool
    let sourceFrame: CGRect

    static func == (lhs: MessageMenuTarget, rhs: MessageMenuTarget) -> Bool {
        lhs.id == rhs.id
    }
}
