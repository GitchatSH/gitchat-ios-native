import SwiftUI

/// Shared state for the swipe-to-reply gesture. Lives at the
/// `ChatView` level; the UITableView coordinator in
/// `ChatMessagesList` drives it from a UIKit `UIPanGestureRecognizer`,
/// and each message cell observes it via `@EnvironmentObject` to
/// apply the visual offset + reply-arrow overlay.
///
/// Driving the gesture from UIKit (rather than a SwiftUI
/// `simultaneousGesture(DragGesture)` per bubble) is what lets the
/// table's own pan still scroll when the user drags on a bubble.
/// SwiftUI's `simultaneousGesture` is only "simultaneous" among
/// SwiftUI gestures — it does NOT configure
/// `shouldRecognizeSimultaneouslyWith` between DragGesture's internal
/// pan recognizer and the UITableView's pan, which is why the bubble
/// used to swallow vertical scrolls.
final class ChatSwipeState: ObservableObject {
    @Published var messageId: String?
    @Published var offsetX: CGFloat = 0
}

/// Visual-only modifier for the swipe-to-reply feedback. Reads the
/// active offset from `ChatSwipeState` and renders the offset bubble
/// plus the reply-arrow icon that fades in past `fadeStart`.
struct ChatSwipeReply: ViewModifier {
    let isMe: Bool
    let messageId: String
    @EnvironmentObject private var swipe: ChatSwipeState

    private let threshold: CGFloat = 60
    private let fadeStart: CGFloat = 20

    private var offsetX: CGFloat {
        swipe.messageId == messageId ? swipe.offsetX : 0
    }

    private var fadeOpacity: Double {
        Double(min(1, max(0, (abs(offsetX) - fadeStart) / (threshold - fadeStart))))
    }

    /// How far the icon slides in from outside the row as the drag
    /// progresses. Stays pinned once the bubble is clearly displaced
    /// so it reads as a fixed target the bubble is sliding toward —
    /// Messages.app behaviour.
    private var iconInset: CGFloat {
        // Icon starts 12pt hidden off the row edge and slides to 0
        // as offsetX approaches threshold.
        let progress = min(1, abs(offsetX) / threshold)
        return 12 * (1 - progress)
    }

    func body(content: Content) -> some View {
        // Wrap content (with its own offset) in a ZStack so its
        // frame is the single source of truth for the row's size,
        // then attach the reply icon as an `.overlay`. Overlays do
        // NOT contribute to parent layout — previously the icon
        // sat as a ZStack sibling, and because the icon is ~34pt
        // tall it inflated short-bubble rows and forced a visible
        // vertical gap between consecutive same-sender messages.
        //
        // The inner `.offset(x:)` only translates rendering, not
        // layout, so the outer ZStack's frame stays = content
        // frame, and the overlay anchors to content's original
        // (pre-offset) edge. Exactly what we want: bubble slides,
        // icon stays pinned to the row's leading/trailing.
        ZStack {
            content
                .offset(x: offsetX)
        }
        .overlay(alignment: isMe ? .trailing : .leading) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color("AccentColor"))
                .padding(10)
                .background(Circle().fill(Color(.secondarySystemBackground)))
                .padding(.horizontal, iconInset)
                .opacity(fadeOpacity)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Apply the swipe-to-reply visual to a message bubble. The actual
    /// gesture lives on the UITableView — see `ChatMessagesList`.
    func chatSwipeToReply(isMe: Bool, messageId: String) -> some View {
        modifier(ChatSwipeReply(isMe: isMe, messageId: messageId))
    }
}
