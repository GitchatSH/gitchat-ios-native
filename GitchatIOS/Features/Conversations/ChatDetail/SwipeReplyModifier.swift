import SwiftUI

/// Horizontal swipe on a bubble triggers reply. Outgoing bubbles accept
/// a leftward drag (toward the composer); incoming bubbles accept a
/// rightward drag. A faint arrow icon fades in as the drag progresses
/// past ~20pt; release past ~60pt triggers; release below springs back.
///
/// The gesture engages only after ≥12pt of horizontal translation so
/// vertical scroll still wins on fast flicks.
struct SwipeReplyModifier: ViewModifier {
    let isMe: Bool
    let onTrigger: () -> Void

    @State private var offsetX: CGFloat = 0
    @State private var triggered = false

    private var threshold: CGFloat { 60 }
    private var iconFade: CGFloat { 20 }

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
                    .opacity(Double(min(1, max(0, (abs(offsetX) - iconFade) / (threshold - iconFade)))))
                    .allowsHitTesting(false)
            }
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { v in
                        // Only accept primarily-horizontal drags in the
                        // expected direction so vertical scroll still wins.
                        let dx = v.translation.width
                        let dy = v.translation.height
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
    func swipeToReply(isMe: Bool, onTrigger: @escaping () -> Void) -> some View {
        modifier(SwipeReplyModifier(isMe: isMe, onTrigger: onTrigger))
    }
}
