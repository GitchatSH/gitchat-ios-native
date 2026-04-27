import SwiftUI

/// Full-screen overlay shown when the user long-presses a message.
/// The bubble stays at its original screen position. Reactions bar
/// appears above, action dropdown below (or above if near bottom).
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
    @State private var reactionsHeight: CGFloat = 0
    @State private var dropdownHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Dimmed + blurred backdrop
                Color.black.opacity(appeared ? 0.35 : 0)
                    .background(.ultraThinMaterial.opacity(appeared ? 1 : 0))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                content(in: geo)
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

    @ViewBuilder
    private func content(in geo: GeometryProxy) -> some View {
        let screenW = geo.size.width
        let screenH = geo.size.height
        let safeTop = geo.safeAreaInsets.top
        let safeBottom = geo.safeAreaInsets.bottom
        let source = target.sourceFrame
        let bubbleMaxWidth = min(screenW - 40, max(source.width, 260))

        // Bubble position — keep at original location with minimal adjustment
        let bubbleW = min(source.width, bubbleMaxWidth)
        let bubbleH = min(source.height, screenH * 0.6) // clip very tall bubbles
        let bubbleX = target.isMe ? screenW - bubbleW - 20 : CGFloat(20)

        // Calculate available space
        let reactionsH = reactionsHeight > 0 ? reactionsHeight : 44
        let dropdownH = dropdownHeight > 0 ? dropdownHeight : 200
        let neededAbove = reactionsH + 8
        let neededBelow = dropdownH + 8

        // Adjust bubble Y if needed to fit reactions above and dropdown below
        let rawBubbleY = source.minY
        let adjustedBubbleY: CGFloat = {
            var y = rawBubbleY
            // Push down if reactions don't fit above
            if y - neededAbove < safeTop {
                y = safeTop + neededAbove
            }
            // Push up if dropdown doesn't fit below
            let bottomEdge = y + bubbleH + neededBelow
            if bottomEdge > screenH - safeBottom {
                y -= bottomEdge - (screenH - safeBottom)
            }
            // Final clamp: at least reactions fit
            return max(safeTop + neededAbove, y)
        }()

        let reactionsY = adjustedBubbleY - reactionsH - 8
        let spaceBelow = screenH - safeBottom - (adjustedBubbleY + bubbleH)
        let dropdownBelow = spaceBelow >= neededBelow
        let dropdownY = dropdownBelow
            ? adjustedBubbleY + bubbleH + 8
            : reactionsY - dropdownH - 8

        // Reactions bar
        reactionsBar
            .frame(maxWidth: .infinity, alignment: target.isMe ? .trailing : .leading)
            .padding(.horizontal, 20)
            .background(GeometryReader { g in
                Color.clear.onAppear { reactionsHeight = g.size.height }
            })
            .scaleEffect(appeared ? 1 : 0.3, anchor: target.isMe ? .bottomTrailing : .bottomLeading)
            .opacity(appeared ? 1 : 0)
            .offset(y: reactionsY)

        // Bubble preview — stays at original position
        HStack {
            if target.isMe { Spacer(minLength: 0) }
            preview()
                .frame(maxWidth: bubbleMaxWidth)
                .frame(maxHeight: bubbleH)
                .clipped()
            if !target.isMe { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 20)
        .scaleEffect(appeared ? 1.02 : 1)
        .animation(
            appeared
                ? .spring(response: 0.3, dampingFraction: 0.6).delay(0.1)
                : .spring(response: 0.28, dampingFraction: 0.85),
            value: appeared
        )
        .offset(y: adjustedBubbleY)

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
        .frame(maxWidth: .infinity, alignment: target.isMe ? .trailing : .leading)
        .padding(.horizontal, 20)
        .background(GeometryReader { g in
            Color.clear.onAppear { dropdownHeight = g.size.height }
        })
        .scaleEffect(appeared ? 1 : 0.4, anchor: target.isMe ? .topTrailing : .topLeading)
        .opacity(appeared ? 1 : 0)
        .offset(y: dropdownY)
    }

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
