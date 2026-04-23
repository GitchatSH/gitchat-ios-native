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

// Note: TypingDots lives in TypingIndicatorRow.swift. This file holds
// animation/transition tokens only; the typing-dots view was considered
// here but the existing implementation already uses a TimelineView and
// needs no replacement.
