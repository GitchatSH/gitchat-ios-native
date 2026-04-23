import SwiftUI

/// Full-screen overlay shown when the user long-presses a message.
/// Bespoke replacement for the default `.contextMenu`:
/// - Background dims + blurs with `.ultraThinMaterial`.
/// - The source bubble is re-rendered in the overlay, starting at its
///   source frame and springing to a centered target position.
/// - A `ReactionPickerBar` sits above, an action list below.
/// - Dismisses on tap outside, on drag down past threshold, or on
///   action selection.
struct MessageMenuOverlay<Preview: View, Actions: View>: View {
    let target: MessageMenuTarget
    let onDismiss: () -> Void
    let onQuickReact: (String) -> Void
    let onMoreReactions: () -> Void
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let actions: () -> Actions

    @State private var appeared = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dimmed / blurred backdrop. Tap anywhere to dismiss.
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
        // Lay the three elements in a vertical stack. Anchor the
        // PREVIEW to where the cell was (source frame) and let the
        // stack spring upward/downward to center as appeared toggles.
        let screenW = geo.size.width
        let source = target.sourceFrame
        let bubbleMaxWidth = min(screenW - 40, max(source.width, 260))

        VStack(spacing: 12) {
            ReactionPickerBar(onPick: { emoji in
                onQuickReact(emoji)
                dismiss()
            }, onMore: {
                onMoreReactions()
                dismiss()
            })
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

            VStack(spacing: 0) {
                actions()
            }
            .frame(maxWidth: 260)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
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

/// Standard button row for the overlay's action list. Supports a
/// destructive tint and an optional leading icon.
struct MessageMenuActionButton: View {
    let title: String
    var systemImage: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                Spacer()
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Divider(), alignment: .bottom)
    }
}
