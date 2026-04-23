import SwiftUI

/// Full-screen overlay presented when the user long-presses a
/// message. Structurally modelled on exyte/chat's `MessageMenu` (MIT)
/// — three-phase state machine (`prepare → ready → dismiss`) that
/// first renders the reaction picker + action list invisibly to
/// capture their intrinsic sizes, then springs everything to a
/// sensible position clamped to the safe area.
///
/// The emoji-search keyboard branch is intentionally omitted; the
/// "more" chevron opens the existing `EmojiPickerSheet` instead.
///
/// Gitchat-specific:
/// - Uses `ChatTheme` env tokens instead of hard-coded colors.
/// - Consumes a `MessageMenuTarget` built by the UIKit long-press
///   recognizer in `ChatMessagesList`, so source frames are pixel
///   accurate without a per-bubble SwiftUI `GeometryReader`.
/// - Action list built from `MessageMenuAction.visibleActions(...)`.
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

    // MARK: Phases

    private enum Phase {
        case prepare   // rendered invisible for one tick to measure
        case ready     // sprung into final position
        case dismiss   // fading out
    }

    @State private var phase: Phase = .prepare

    // MARK: Measurements (filled during `.prepare`)

    @State private var bubbleSize: CGSize = .zero
    @State private var reactionBarSize: CGSize = .zero
    @State private var actionListSize: CGSize = .zero

    // MARK: Drag-to-dismiss

    @State private var dragOffset: CGFloat = 0

    // MARK: Spacing tokens

    private let gap: CGFloat = 8
    private let edgeInset: CGFloat = 12
    private let springReady = Animation.spring(response: 0.34, dampingFraction: 0.78)
    private let springDismiss = Animation.spring(response: 0.24, dampingFraction: 0.9)
    private let bgFade = Animation.easeOut(duration: 0.2)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                backdrop
                content(in: geo)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear { onFirstAppear() }
    }

    // MARK: Backdrop

    @ViewBuilder
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            theme.menuBackdrop.opacity(0.18)
        }
        .opacity(phase == .ready ? 1 : 0)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { beginDismiss() }
    }

    // MARK: Stack content

    @ViewBuilder
    private func content(in geo: GeometryProxy) -> some View {
        let source = target.sourceFrame
        let screenW = geo.size.width
        let screenH = geo.size.height
        let safeTop = geo.safeAreaInsets.top
        let safeBottom = geo.safeAreaInsets.bottom

        // Target center Y — prefer the source's vertical center,
        // clamped so the reaction bar + action list fit in the safe
        // area. If the total stack is taller than the safe band, we
        // pin the top edge to the safe top and let the list overflow
        // (overflow scrolling is a future polish — Gitchat rarely has
        // > 7 actions so the list is ~ 400pt tall max).
        let totalHeight = reactionBarSize.height + gap
            + bubbleSize.height + gap
            + actionListSize.height
        let minCenterY = safeTop + edgeInset + totalHeight / 2
        let maxCenterY = screenH - safeBottom - edgeInset - totalHeight / 2
        let preferredCenter = source.midY
        let targetCenterY = min(max(minCenterY, preferredCenter), maxCenterY)

        // Compute origin of each component relative to the final stack
        // center. These only drive the `.ready` phase; during `.prepare`
        // we pin everything to the source frame so the transition is
        // visually continuous.
        let stackTopY = targetCenterY - totalHeight / 2
        let barCenterY = stackTopY + reactionBarSize.height / 2
        let bubbleCenterY = stackTopY + reactionBarSize.height + gap + bubbleSize.height / 2
        let actionsCenterY = stackTopY + reactionBarSize.height + gap
            + bubbleSize.height + gap + actionListSize.height / 2

        // Horizontal — right-aligned for own messages, left-aligned for
        // incoming. Clamped so components don't run past the edge.
        let alignRight = target.isMe
        let bubbleCenterX: CGFloat = source.midX
        let barCenterX: CGFloat = alignRight
            ? (source.maxX - reactionBarSize.width / 2)
            : (source.minX + reactionBarSize.width / 2)
        let actionsCenterX: CGFloat = alignRight
            ? (source.maxX - actionListSize.width / 2)
            : (source.minX + actionListSize.width / 2)

        // Reaction picker
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
        .sizeReader { size in reactionBarSize = size }
        .scaleEffect(phase == .ready ? 1 : 0.2,
                     anchor: alignRight ? .bottomTrailing : .bottomLeading)
        .opacity(phase == .ready ? 1 : 0)
        .position(
            x: phase == .ready
                ? clamp(barCenterX, low: edgeInset + reactionBarSize.width / 2,
                        high: screenW - edgeInset - reactionBarSize.width / 2)
                : source.midX,
            y: (phase == .ready ? barCenterY : source.midY) + dragOffset
        )

        // Re-rendered bubble
        preview()
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: min(screenW - 2 * edgeInset, max(source.width, 280)))
            .sizeReader { size in bubbleSize = size }
            .position(
                x: phase == .ready
                    ? clamp(bubbleCenterX, low: edgeInset + bubbleSize.width / 2,
                            high: screenW - edgeInset - bubbleSize.width / 2)
                    : source.midX,
                y: (phase == .ready ? bubbleCenterY : source.midY) + dragOffset
            )
            .gesture(
                DragGesture()
                    .onChanged { v in dragOffset = max(0, v.translation.height) }
                    .onEnded { v in
                        if v.translation.height > 80 { beginDismiss() }
                        else {
                            withAnimation(springReady) { dragOffset = 0 }
                        }
                    }
            )

        // Action list
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
        .sizeReader { size in actionListSize = size }
        .scaleEffect(phase == .ready ? 1 : 0.25,
                     anchor: alignRight ? .topTrailing : .topLeading)
        .opacity(phase == .ready ? 1 : 0)
        .position(
            x: phase == .ready
                ? clamp(actionsCenterX, low: edgeInset + actionListSize.width / 2,
                        high: screenW - edgeInset - actionListSize.width / 2)
                : source.midX,
            y: (phase == .ready ? actionsCenterY : source.midY) + dragOffset
        )
    }

    // MARK: Transitions

    private func onFirstAppear() {
        // One tick to let .prepare render + PreferenceKeys populate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
            withAnimation(springReady) {
                phase = .ready
            }
            withAnimation(bgFade) { /* backdrop fades via phase == .ready */ }
        }
    }

    private func beginDismiss() {
        withAnimation(springDismiss) {
            phase = .dismiss
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            onDismiss()
        }
    }

    private func clamp(_ v: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard low <= high else { return (low + high) / 2 }
        return min(max(v, low), high)
    }
}

// MARK: - Size-reader modifier

/// Reads a view's rendered size into a closure via `PreferenceKey`,
/// deduped so repeated equal writes don't re-trigger SwiftUI updates.
/// Used inside `MessageMenu` during the `.prepare` phase so the
/// positioning math can pick up actual component sizes.
extension View {
    fileprivate func sizeReader(_ onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MessageMenuSizePrefKey.self,
                    value: proxy.size
                )
            }
        )
        .onPreferenceChange(MessageMenuSizePrefKey.self) { size in
            onChange(size)
        }
    }
}

private struct MessageMenuSizePrefKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        // Take the larger of the two — during `.prepare` the component
        // may be measured once at its natural size, and we want to
        // retain that even if transient zero-sized reads arrive.
        if next.width > value.width { value.width = next.width }
        if next.height > value.height { value.height = next.height }
    }
}
