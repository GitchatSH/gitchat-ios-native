import SwiftUI

/// Full-screen overlay presented when the user long-presses a
/// message. Layout philosophy — matches how Telegram handles the
/// long-press menu:
/// 1. Reaction bar + action list are both rendered at their natural
///    intrinsic sizes (measured via PreferenceKey).
/// 2. The bubble preview is given whatever vertical space REMAINS
///    after the reaction bar + action list + gaps + safe-area insets.
///    If the preview's content is taller than that budget it lands
///    inside a ScrollView so the user can still scan the full
///    message — but the bar + list never get pushed off-screen.
/// 3. The whole column is aligned to the sender side and placed
///    vertically so the preview lines up roughly with the source
///    cell's original Y, clamped to the safe area.
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
    @State private var reactionBarHeight: CGFloat = 52
    @State private var actionListHeight: CGFloat = 0

    private let gap: CGFloat = 10
    private let edgeInset: CGFloat = 14
    private let showAnim = Animation.spring(response: 0.32, dampingFraction: 0.78)
    private let hideAnim = Animation.spring(response: 0.24, dampingFraction: 0.9)

    var body: some View {
        GeometryReader { geo in
            let layout = computeLayout(in: geo)

            ZStack(alignment: .top) {
                backdrop
                column(maxPreviewHeight: layout.maxPreviewHeight)
                    .frame(
                        maxWidth: geo.size.width - 2 * edgeInset,
                        alignment: target.isMe ? .trailing : .leading
                    )
                    .padding(.horizontal, edgeInset)
                    .offset(y: layout.topOffset + dragOffset)
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

    // MARK: Column

    @ViewBuilder
    private func column(maxPreviewHeight: CGFloat) -> some View {
        VStack(alignment: target.isMe ? .trailing : .leading, spacing: gap) {
            reactionBar
            previewSlot(maxHeight: maxPreviewHeight)
            actionList
        }
    }

    @ViewBuilder
    private var reactionBar: some View {
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
        .sizeReader { size in
            // Async hop: onPreferenceChange can fire during SwiftUI's
            // view-update pass, and writing @State synchronously from
            // there triggers the "Modifying state during view update,
            // this will cause undefined behavior" warning + layout
            // thrash.
            let h = size.height
            DispatchQueue.main.async {
                if h > reactionBarHeight { reactionBarHeight = h }
            }
        }
        .scaleEffect(
            appeared ? 1 : 0.2,
            anchor: target.isMe ? .bottomTrailing : .bottomLeading
        )
        .opacity(appeared ? 1 : 0)
    }

    @ViewBuilder
    private func previewSlot(maxHeight: CGFloat) -> some View {
        // Preview is budgeted: natural size up to `maxHeight`, then
        // ScrollView for overflow so very long bubbles stay readable
        // without pushing the action list off screen.
        ScrollView(.vertical, showsIndicators: false) {
            preview()
                .fixedSize(horizontal: false, vertical: true)
                .scaleEffect(
                    appeared ? 1 : 0.88,
                    anchor: target.isMe ? .trailing : .leading
                )
                .opacity(appeared ? 1 : 0)
        }
        .frame(maxHeight: maxHeight)
        .scrollDisabled(false)
    }

    @ViewBuilder
    private var actionList: some View {
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
        .sizeReader { size in
            let h = size.height
            DispatchQueue.main.async {
                if h > actionListHeight { actionListHeight = h }
            }
        }
        .scaleEffect(
            appeared ? 1 : 0.3,
            anchor: target.isMe ? .topTrailing : .topLeading
        )
        .opacity(appeared ? 1 : 0)
    }

    // MARK: Layout budget

    private struct Layout {
        let maxPreviewHeight: CGFloat
        let topOffset: CGFloat
    }

    private func computeLayout(in geo: GeometryProxy) -> Layout {
        let source = target.sourceFrame
        let safeTop = geo.safeAreaInsets.top + edgeInset
        let safeBottom = geo.safeAreaInsets.bottom + edgeInset
        let available = geo.size.height - safeTop - safeBottom
        // Reserve space for the reaction bar + action list + two gaps.
        let budget = available
            - reactionBarHeight
            - actionListHeight
            - 2 * gap
        let maxPreviewHeight = max(120, budget)

        // Desired top — anchor the preview near where the source cell
        // was. If the source was near the screen bottom (common — user
        // tapped on the most recent message), that pushes too far down,
        // so clamp to keep the top of the stack visible.
        let stackHeightEstimate = reactionBarHeight + actionListHeight
            + min(maxPreviewHeight, max(120, source.height)) + 2 * gap
        let preferredTop = source.minY - reactionBarHeight - gap
        let maxTop = geo.size.height - geo.safeAreaInsets.bottom - edgeInset - stackHeightEstimate
        let clampedTop = max(safeTop, min(preferredTop, maxTop))

        // During the enter animation, slide a hair down from the source
        // cell so the preview "flies in" feeling stays.
        let closedTop = max(safeTop, source.minY - 30)
        return Layout(
            maxPreviewHeight: maxPreviewHeight,
            topOffset: appeared ? clampedTop : closedTop
        )
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

// MARK: - Size-reader modifier

/// Reads a view's rendered size into a closure via `PreferenceKey`.
/// Used inside `MessageMenu` to budget the preview's height based on
/// the reaction bar + action list's actual rendered heights.
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
        value = nextValue()
    }
}
