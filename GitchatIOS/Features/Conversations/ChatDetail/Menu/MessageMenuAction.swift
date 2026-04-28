import SwiftUI

/// Strongly-typed enum of every action a user can invoke from the
/// message menu. The set of actions visible for a given message is
/// computed by `visibleActions(for:isMe:isGroup:isPinned:)` — mirroring
/// the conditional rendering in the legacy `messageActions(for:)` on
/// `ChatDetailView` — so callers never have to re-derive the
/// visibility rules.
///
/// Ported from exyte/chat's `DefaultMessageMenuAction` shape (MIT) but
/// expanded to cover Gitchat's full feature set.
enum MessageMenuAction: Hashable {
    case reply
    case copyText
    case copyImage
    case pin
    case unpin
    case forward
    case seenBy
    case edit
    case unsend
    case delete
    case report
    case saveToPhotos
    case retry
    case discard

    func title(seenCount: Int = 0) -> String {
        switch self {
        case .reply: return "Reply"
        case .copyText: return "Copy"
        case .copyImage: return "Copy Image"
        case .saveToPhotos: return "Save to Photos"
        case .pin: return "Pin"
        case .unpin: return "Unpin"
        case .forward: return "Forward"
        case .seenBy: return seenCount > 0 ? "Seen by \(seenCount)" : "Seen by"
        case .edit: return "Edit"
        case .unsend: return "Unsend"
        case .delete: return "Delete"
        case .report: return "Report"
        case .retry: return "Retry"
        case .discard: return "Discard"
        }
    }

    var systemImage: String {
        switch self {
        case .reply: return "arrowshape.turn.up.left"
        case .copyText: return "doc.on.doc"
        case .copyImage: return "photo.on.rectangle"
        case .saveToPhotos: return "square.and.arrow.down"
        case .pin: return "pin"
        case .unpin: return "pin.slash"
        case .forward: return "arrowshape.turn.up.right"
        case .seenBy: return "eye"
        case .edit: return "pencil"
        case .unsend: return "arrow.uturn.backward"
        case .delete: return "trash"
        case .report: return "flag"
        case .retry: return "arrow.clockwise"
        case .discard: return "trash"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .delete, .report, .unsend, .discard: return true
        case .reply, .copyText, .copyImage, .saveToPhotos, .pin, .unpin,
             .forward, .seenBy, .edit, .retry: return false
        }
    }

    /// Decide which actions are visible for a given message given the
    /// surrounding context. Returns an ordered list — render it as-is.
    static func visibleActions(
        for message: Message,
        isMe: Bool,
        isGroup: Bool,
        isPinned: Bool,
        hasText: Bool,
        hasImageAttachment: Bool
    ) -> [MessageMenuAction] {
        var out: [MessageMenuAction] = [.reply]
        if hasText { out.append(.copyText) }
        if hasImageAttachment {
            out.append(.copyImage)
            out.append(.saveToPhotos)
        }
        out.append(isPinned ? .unpin : .pin)
        out.append(.forward)
        if isGroup || isMe { out.append(.seenBy) }
        if isMe {
            out.append(contentsOf: [.edit, .unsend, .delete])
        } else {
            out.append(.report)
        }
        return out
    }
}
