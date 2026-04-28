import UIKit

/// Shared cache storing each message bubble's screen-space frame.
/// Written by ChatMessageView via GeometryReader, read by the
/// long-press handler to get exact bubble coordinates for the menu.
final class BubbleFrameCache {
    static let shared = BubbleFrameCache()
    private var frames: [String: CGRect] = [:]

    func set(_ frame: CGRect, for messageId: String) {
        frames[messageId] = frame
    }

    func frame(for messageId: String) -> CGRect? {
        frames[messageId]
    }

    func removeAll() {
        frames.removeAll()
    }
}
