import SwiftUI

// MARK: - JumpButtonStack

/// Vertically-stacked floating action buttons shown above the composer.
/// Shows up to 2 buttons (reaction button deferred):
///   1. @-mention jump  — only when there are unread mentions
///   2. Scroll-to-bottom — when not at bottom, with optional unread badge
struct JumpButtonStack: View {
    let isAtBottom: Bool
    let unreadCount: Int
    let mentionCount: Int
    let onJumpToBottom: () -> Void
    let onJumpToMention: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if mentionCount > 0 {
                jumpButton(
                    label: {
                        Text("@")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Color("AccentColor"))
                    },
                    badge: mentionCount,
                    tooltip: "Jump to mention",
                    action: onJumpToMention
                )
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if !isAtBottom {
                jumpButton(
                    label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    },
                    badge: unreadCount > 0 ? unreadCount : nil,
                    tooltip: "Jump to latest",
                    action: onJumpToBottom
                )
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isAtBottom)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: mentionCount)
    }

    // MARK: - Single button builder

    private func jumpButton<L: View>(
        label: () -> L,
        badge: Int?,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: { Haptics.selection(); action() }) {
            if #available(iOS 26.0, *) {
                ZStack {
                    Circle()
                        .fill(.clear)
                        .frame(width: 32, height: 32)
                    label()
                }
                .frame(width: 38, height: 38)
                .glassEffect(.regular, in: .circle)
            } else {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    label()
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44) // 44pt touch target
        .overlay(alignment: .top) {
            if let badge = badge, badge > 0 {
                Text(badge > 99 ? "99+" : "\(badge)")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color("AccentColor"), in: Capsule())
                    .offset(y: -4)
            }
        }
        .instantTooltip(tooltip)
    }
}

// MARK: - Legacy alias

/// Backward-compatible single button. Delegates to `JumpButtonStack`.
struct JumpToBottomButton: View {
    let action: () -> Void

    var body: some View {
        JumpButtonStack(
            isAtBottom: false,
            unreadCount: 0,
            mentionCount: 0,
            onJumpToBottom: action,
            onJumpToMention: {}
        )
    }
}
