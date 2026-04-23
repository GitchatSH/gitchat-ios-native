import SwiftUI

/// Canonical animation + transition definitions for the chat screen.
/// Pull from here rather than defining one-off `.spring(...)` calls so
/// the feel stays consistent across bubbles, reactions, overlays, and
/// scroll-to-bottom controls.
enum ChatAnimations {
    // MARK: - Springs

    /// Gentle bounce for bubble appear / reaction pop / chevron toggles.
    static let pop: Animation = .spring(response: 0.28, dampingFraction: 0.62)

    /// Firmer spring for menu overlays and scroll pills.
    static let overlay: Animation = .spring(response: 0.32, dampingFraction: 0.78)

    /// Low-bounce spring for snap-back gestures (swipe-to-reply, drag
    /// dismiss on the menu).
    static let snapBack: Animation = .spring(response: 0.32, dampingFraction: 0.72)

    /// Two-stage highlight timing used by the reply-pulse path.
    static let pulseIn: Animation = .easeInOut(duration: 0.25)
    static let pulseOut: Animation = .easeInOut(duration: 0.3)

    // MARK: - Transitions

    /// First-time bubble appearance: gentle scale + fade. Removal uses
    /// a simple opacity so "delete message" does not re-shrink.
    static let bubbleAppear: AnyTransition = .asymmetric(
        insertion: .scale(scale: 0.92).combined(with: .opacity),
        removal: .opacity
    )

    /// Reaction chip appear / disappear.
    static let reactionChip: AnyTransition = .scale(scale: 0.3).combined(with: .opacity)

    /// Seen-by avatar row.
    static let seenRow: AnyTransition = .scale(scale: 0.5).combined(with: .opacity)

    /// Menu overlay hero transition.
    static let menuOverlay: AnyTransition = .opacity.combined(with: .scale(scale: 0.96))
}

/// Typing-dots indicator driven by `TimelineView` so it keeps animating
/// while the collection view is applying snapshot diffs (a plain
/// `.animation` modifier freezes during diffable apply).
struct TypingDots: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * phase(at: t, i: i))
                        .scaleEffect(0.85 + 0.15 * phase(at: t, i: i))
                }
            }
        }
    }

    private func phase(at t: TimeInterval, i: Int) -> Double {
        let cycle = 1.1
        let delay = Double(i) * 0.15
        let x = (t.truncatingRemainder(dividingBy: cycle) - delay) / cycle
        let clamped = max(0, min(1, x))
        return 0.5 * (1 + sin(clamped * 2 * .pi - .pi / 2))
    }
}
