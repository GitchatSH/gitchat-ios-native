import SwiftUI

/// Full-screen overlay presented when the user long-presses a
/// message. Uses SwiftUI's natural layout (a VStack of reaction
/// picker + preview bubble + action list) positioned near the source
/// cell's center — instead of absolute positioning with a measure-
/// then-lay-out dance, which raced the animation and caused the
/// reaction bar to never appear.
///
/// Position rules:
/// - Stack centers near `source.midY`, clamped to stay inside the
///   safe area. SwiftUI lays out the VStack at its intrinsic size
///   so every component is always visible.
/// - The picker + list are horizontally anchored to the sender side
///   (leading for incoming, trailing for own) via a HStack + Spacer
///   inside the VStack — which is how iMessage aligns them.
struct MessageMenu<Preview: View>: View {
    @Environment(\.chatTheme) private var theme

    let target: MessageMenuTarget
    let actions: [MessageMenuAction]
    let currentReactions: Set<String>
    let seenCount: Int
    let onReact: (String) -> Void
    let onMoreReactions: () -> Void
    let onAction: (MessageMenuAction) -> Void
    let onDismiss: () -> Void
    @ViewBuilder let preview: () -> Preview

    @State private var appeared = false
    @State private var dragOffset: CGFloat = 0

    private let gap: CGFloat = 10
    private let edgeInset: CGFloat = 14
    private let showAnim = Animation.spring(response: 0.32, dampingFraction: 0.78)
    private let hideAnim = Animation.spring(response: 0.24, dampingFraction: 0.9)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                backdrop

                stack
                    .frame(
                        maxWidth: geo.size.width - 2 * edgeInset,
                        alignment: target.isMe ? .trailing : .leading
                    )
                    .padding(.horizontal, edgeInset)
                    .offset(y: centerOffset(in: geo) + dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { v in dragOffset = max(0, v.translation.height) }
                            .onEnded { v in
                                if v.translation.height > 80 { beginDismiss() }
                                else {
                                    withAnimation(showAnim) { dragOffset = 0 }
                                }
                            }
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(showAnim) { appeared = true }
        }
    }

    // MARK: Backdrop

    @ViewBuilder
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            theme.menuBackdrop.opacity(0.18)
        }
        .opacity(appeared ? 1 : 0)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { beginDismiss() }
    }

    // MARK: Vertical stack (reaction bar + preview + action list)

    @ViewBuilder
    private var stack: some View {
        VStack(alignment: target.isMe ? .trailing : .leading, spacing: gap) {
            ReactionSelectionView(
                currentReactions: currentReactions,
                onPick: { emoji in
                    onReact(emoji)
                    beginDismiss()
                },
                onMore: {
                    beginDismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                        onMoreReactions()
                    }
                }
            )
            .fixedSize()
            .scaleEffect(
                appeared ? 1 : 0.2,
                anchor: target.isMe ? .bottomTrailing : .bottomLeading
            )
            .opacity(appeared ? 1 : 0)

            preview()
                .fixedSize(horizontal: false, vertical: true)
                .scaleEffect(
                    appeared ? 1 : 0.88,
                    anchor: target.isMe ? .trailing : .leading
                )
                .opacity(appeared ? 1 : 0)

            MessageMenuActionList(
                actions: actions,
                seenCount: seenCount,
                onAction: { action in
                    onAction(action)
                    beginDismiss()
                }
            )
            .frame(maxWidth: 240)
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(
                appeared ? 1 : 0.3,
                anchor: target.isMe ? .topTrailing : .topLeading
            )
            .opacity(appeared ? 1 : 0)
        }
    }

    // MARK: Position

    /// Vertical offset of the stack's TOP edge relative to the
    /// container's top edge. Before `appeared`, anchors to the source
    /// cell's top so the preview grows out of the cell's position.
    /// After `appeared`, SwiftUI lays the VStack out naturally near
    /// the source's vertical center, clamped to the safe area.
    private func centerOffset(in geo: GeometryProxy) -> CGFloat {
        let source = target.sourceFrame
        let safeTop = geo.safeAreaInsets.top + edgeInset
        let safeBottom = geo.size.height - geo.safeAreaInsets.bottom - edgeInset
        // Start position: source's top edge, minus some room so the
        // reaction bar grows up from above the bubble.
        if !appeared { return max(safeTop, source.minY - 60) }
        // Final position: prefer anchoring the preview to the source's
        // minY so the bubble stays near where the user tapped; if
        // that would push the tail off the bottom of the safe area,
        // slide up so the action list is fully visible. We don't know
        // the stack's exact height here — rely on SwiftUI to place
        // the stack and clamp.
        let preferred = source.minY - 64
        return max(safeTop, min(preferred, safeBottom - 360))
    }

    // MARK: Transitions

    private func beginDismiss() {
        withAnimation(hideAnim) {
            appeared = false
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            onDismiss()
        }
    }
}
