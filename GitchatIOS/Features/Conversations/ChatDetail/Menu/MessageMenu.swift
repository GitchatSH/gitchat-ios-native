import SwiftUI

/// Full-screen overlay shown when the user long-presses a message.
/// The bubble stays near its original screen position. Reactions bar
/// appears above, action dropdown below.
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

    var body: some View {
        GeometryReader { geo in
            ZStack {
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
        let source = target.sourceFrame
        // source.width may include avatar col + spacers — use 70% screen as max
        let bubbleMaxWidth = min(screenW * 0.7, max(source.width, 260))

        // Convert source.midY from window coords to geo-local coords.
        let geoOriginY = geo.frame(in: .global).minY
        let localMidY = source.midY - geoOriginY

        // Position the VStack so the BUBBLE (middle element) lands near
        // the original Y. Reactions bar (~44pt + 12pt spacing) sits above,
        // so shift the VStack center DOWN by ~half the reactions height
        // to compensate.
        let reactionsOffset: CGFloat = 28 // ~(44 + 12) / 2
        let targetY = localMidY + reactionsOffset
        let minY = screenH * 0.2
        let maxY = screenH * 0.8

        let clampedY = appeared
            ? max(minY, min(targetY, maxY))
            : localMidY

        VStack(spacing: 12) {
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
            .frame(maxWidth: .infinity, alignment: target.isMe ? .trailing : .leading)
            .padding(.horizontal, 20)
            .scaleEffect(appeared ? 1 : 0.3, anchor: target.isMe ? .topTrailing : .topLeading)
            .opacity(appeared ? 1 : 0)

            HStack {
                if target.isMe { Spacer(minLength: 0) }
                preview()
                    .frame(maxWidth: bubbleMaxWidth)
                if !target.isMe { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 20)
            .scaleEffect(appeared ? 1.015 : 1)
            .animation(
                appeared
                    ? .spring(response: 0.3, dampingFraction: 0.6).delay(0.1)
                    : .spring(response: 0.28, dampingFraction: 0.85),
                value: appeared
            )

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
            .scaleEffect(appeared ? 1 : 0.4, anchor: target.isMe ? .topTrailing : .topLeading)
            .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .position(
            x: geo.size.width / 2,
            y: clampedY
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
