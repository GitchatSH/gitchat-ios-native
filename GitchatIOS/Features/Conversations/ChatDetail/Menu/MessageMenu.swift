import SwiftUI

/// Full-screen overlay shown when the user long-presses a message.
/// Ported verbatim from the `feat/chat-rework` branch's working
/// version — the simpler spring-to-center layout without measure-
/// then-position gymnastics. Three elements in a VStack (reaction
/// bar, preview bubble, action list); the whole column springs into
/// the vertical center of the screen; each element also scales in
/// from the sender-side anchor.
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
                // Dimmed + blurred backdrop. Tap anywhere to dismiss.
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
        let source = target.sourceFrame
        let bubbleMaxWidth = min(screenW - 40, max(source.width, 260))

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
            y: appeared
                ? max(geo.size.height * 0.5, min(source.midY, geo.size.height * 0.55))
                : source.midY
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
