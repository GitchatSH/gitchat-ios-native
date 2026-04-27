import SwiftUI

/// Full-screen overlay shown when the user long-presses a message.
/// The bubble stays at its original screen position. Reactions bar
/// appears above, action dropdown below. Only adjusts position if
/// reactions would overlap the header or dropdown would be clipped.
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
    @State private var reactionsSize: CGSize = .zero
    @State private var dropdownSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let layout = computeLayout(in: geo)

            ZStack {
                // Dimmed + blurred backdrop
                Color.black.opacity(appeared ? 0.35 : 0)
                    .background(.ultraThinMaterial.opacity(appeared ? 1 : 0))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                Group {
                    // Reactions bar
                    reactionsBar
                        .fixedSize()
                        .background(GeometryReader { g in
                            Color.clear.onAppear { reactionsSize = g.size }
                        })
                        .frame(maxWidth: .infinity, alignment: target.isMe ? .trailing : .leading)
                        .padding(.horizontal, 20)
                        .scaleEffect(appeared ? 1 : 0.3, anchor: target.isMe ? .bottomTrailing : .bottomLeading)
                        .opacity(appeared ? 1 : 0)
                        .position(x: geo.size.width / 2, y: layout.reactionsY)

                    // Bubble preview at exact original position + width
                    preview()
                        .frame(width: layout.bubbleW)
                        .scaleEffect(appeared ? 1.015 : 1)
                        .animation(
                            appeared
                                ? .spring(response: 0.3, dampingFraction: 0.6).delay(0.1)
                                : .spring(response: 0.28, dampingFraction: 0.85),
                            value: appeared
                        )
                        .position(x: layout.bubbleCenterX, y: layout.bubbleCenterY)

                    // Action dropdown
                    MessageMenuActionList(
                        actions: actions,
                        seenCount: seenCount,
                        onAction: { action in
                            onAction(action)
                            dismiss()
                        }
                    )
                    .frame(maxWidth: 260)
                    .background(GeometryReader { g in
                        Color.clear.onAppear { dropdownSize = g.size }
                    })
                    .frame(maxWidth: .infinity, alignment: target.isMe ? .trailing : .leading)
                    .padding(.horizontal, 20)
                    .scaleEffect(appeared ? 1 : 0.4, anchor: target.isMe ? .topTrailing : .topLeading)
                    .opacity(appeared ? 1 : 0)
                    .position(x: geo.size.width / 2, y: layout.dropdownY)
                }
                .offset(y: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            dragOffset = max(0, v.translation.height)
                        }
                        .onEnded { v in
                            if v.translation.height > 80 { dismiss() }
                            else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }

    // MARK: - Layout computation

    private struct Layout {
        let bubbleCenterX: CGFloat
        let bubbleCenterY: CGFloat
        let bubbleW: CGFloat
        let reactionsY: CGFloat
        let dropdownY: CGFloat
    }

    private func computeLayout(in geo: GeometryProxy) -> Layout {
        let source = target.sourceFrame
        let geoOrigin = geo.frame(in: .global)
        let safeTop = geo.safeAreaInsets.top
        let screenH = geo.size.height

        // Convert source frame from window coords to geo-local coords
        let bubbleTop = source.minY - geoOrigin.minY
        let bubbleCenterX = source.midX - geoOrigin.minX
        let bubbleH = source.height
        let bubbleW = source.width

        let reactionsH = reactionsSize.height > 0 ? reactionsSize.height : 44
        let dropdownH = dropdownSize.height > 0 ? dropdownSize.height : 200
        let gap: CGFloat = 8

        // Default: bubble at original position
        var adjustedBubbleTop = bubbleTop

        // Case 1: reactions would overlap header (safe area top)
        let reactionsTop = adjustedBubbleTop - gap - reactionsH
        if reactionsTop < safeTop {
            adjustedBubbleTop = safeTop + reactionsH + gap
        }

        // Case 2: dropdown would be clipped at bottom
        let dropdownBottom = adjustedBubbleTop + bubbleH + gap + dropdownH
        if dropdownBottom > screenH {
            let overflow = dropdownBottom - screenH
            adjustedBubbleTop -= overflow
        }

        // Re-check reactions after adjustment
        let finalReactionsTop = adjustedBubbleTop - gap - reactionsH
        if finalReactionsTop < safeTop {
            adjustedBubbleTop = safeTop + reactionsH + gap
        }

        // .position() uses center point
        let bubbleCenterY = adjustedBubbleTop + bubbleH / 2
        let reactionsY = adjustedBubbleTop - gap - reactionsH / 2
        let dropdownY = adjustedBubbleTop + bubbleH + gap + dropdownH / 2

        return Layout(
            bubbleCenterX: bubbleCenterX,
            bubbleCenterY: bubbleCenterY,
            bubbleW: bubbleW,
            reactionsY: reactionsY,
            dropdownY: dropdownY
        )
    }

    // MARK: - Subviews

    private var reactionsBar: some View {
        ReactionSelectionView(
            currentReactions: currentReactions,
            onPick: { emoji in
                onReact(emoji)
                dismiss()
            },
            onMore: {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    onMoreReactions()
                }
            }
        )
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            appeared = false
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            onDismiss()
        }
    }
}
