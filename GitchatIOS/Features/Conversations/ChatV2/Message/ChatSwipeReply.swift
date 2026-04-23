import SwiftUI

/// Horizontal-drag modifier that fires `onTrigger` when the user
/// swipes past a threshold in the direction appropriate for the
/// message's sender. A reply-arrow icon fades in as the user drags.
///
/// Gesture tuning:
/// - Minimum 12pt horizontal displacement before the gesture engages
///   so vertical list scroll still wins on fast flicks.
/// - Haptic selection fires once on threshold crossing (not on every
///   frame past it).
/// - Release below threshold springs back with `snapBack` feel.
struct ChatSwipeReply: ViewModifier {
    let isMe: Bool
    let onTrigger: () -> Void

    @State private var offsetX: CGFloat = 0
    @State private var triggered = false

    private let threshold: CGFloat = 60
    private let fadeStart: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .offset(x: offsetX)
            .overlay(alignment: isMe ? .trailing : .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color("AccentColor"))
                    .padding(10)
                    .background(Circle().fill(Color(.secondarySystemBackground)))
                    .offset(x: isMe ? (abs(offsetX) - 36) : (-abs(offsetX) + 36))
                    .opacity(
                        Double(min(1, max(0, (abs(offsetX) - fadeStart) / (threshold - fadeStart))))
                    )
                    .allowsHitTesting(false)
            }
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { v in
                        let dx = v.translation.width
                        let dy = v.translation.height
                        // Only engage for predominantly-horizontal drags
                        // toward the expected side.
                        guard abs(dx) > abs(dy) * 1.2 else { return }
                        if isMe {
                            offsetX = min(0, max(-threshold * 1.4, dx))
                        } else {
                            offsetX = max(0, min(threshold * 1.4, dx))
                        }
                        if !triggered, abs(offsetX) >= threshold {
                            triggered = true
                            Haptics.selection()
                        } else if triggered, abs(offsetX) < threshold {
                            triggered = false
                        }
                    }
                    .onEnded { _ in
                        let shouldFire = triggered
                        triggered = false
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                            offsetX = 0
                        }
                        if shouldFire { onTrigger() }
                    }
            )
    }
}

extension View {
    /// Apply `ChatSwipeReply` to a message bubble. `isMe` drives
    /// direction (outgoing drags left, incoming drags right).
    func chatSwipeToReply(isMe: Bool, onTrigger: @escaping () -> Void) -> some View {
        modifier(ChatSwipeReply(isMe: isMe, onTrigger: onTrigger))
    }
}
