import SwiftUI

/// Full-screen overlay shown when the user long-presses a message.
/// Ported structurally from exyte/chat (MIT):
/// - The message stays at its original cell frame — we don't fly it.
/// - Background dims + blurs behind it.
/// - Reaction picker fades in directly above the bubble.
/// - Action list fades in directly below the bubble.
/// - The whole stack is clamped to the safe area: if the reaction bar
///   would clip the top, the content slides down; if the action list
///   would clip the bottom, it slides up.
/// - Dismisses on background tap, drag-down past threshold, or action.
struct MessageMenuOverlay<Preview: View, Actions: View>: View {
    let target: MessageMenuTarget
    let onDismiss: () -> Void
    let onQuickReact: (String) -> Void
    let onMoreReactions: () -> Void
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let actions: () -> Actions

    @State private var appeared = false
    @State private var dragOffset: CGFloat = 0
    @State private var reactionBarHeight: CGFloat = 56
    @State private var actionListHeight: CGFloat = 0

    /// Gap between the bubble and the reaction bar / action list.
    private let gap: CGFloat = 8
    /// Minimum padding from screen edges.
    private let edge: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let source = target.sourceFrame
            let safeTop = geo.safeAreaInsets.top
            let safeBottom = geo.safeAreaInsets.bottom
            let screenH = geo.size.height

            // Desired positions before clamping:
            // - reaction bar TOP = source.minY - gap - reactionBarHeight
            // - action list TOP = source.maxY + gap
            let desiredBarTop = source.minY - gap - reactionBarHeight
            let desiredActionsTop = source.maxY + gap

            // Clamp: if bar goes above safe area, push everything down by
            // the overflow; if actions go past bottom safe area, push up.
            let overflowTop = max(0, safeTop + edge - desiredBarTop)
            let overflowBottom = max(
                0,
                (desiredActionsTop + actionListHeight)
                    - (screenH - safeBottom - edge)
            )
            // Prefer bottom correction (pushes up) when both occur.
            let shift = overflowTop - overflowBottom

            ZStack(alignment: .topLeading) {
                // Dimmed / blurred backdrop. Tap anywhere to dismiss.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(appeared ? 1 : 0)
                    .overlay(Color.black.opacity(appeared ? 0.18 : 0))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                // The message bubble at its ORIGINAL cell frame.
                preview()
                    .frame(width: source.width, height: source.height, alignment: .topLeading)
                    .position(x: source.midX, y: source.midY + shift + dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                dragOffset = max(0, v.translation.height)
                            }
                            .onEnded { v in
                                if v.translation.height > 80 { dismiss() }
                                else {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
                    .allowsHitTesting(true)

                // Reaction picker — anchored to the bubble's top edge,
                // aligned to the bubble's leading or trailing edge.
                ReactionPickerBar(
                    onPick: { emoji in
                        onQuickReact(emoji)
                        dismiss()
                    },
                    onMore: {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                            onMoreReactions()
                        }
                    }
                )
                .heightReader($reactionBarHeight)
                .fixedSize()
                .scaleEffect(
                    appeared ? 1 : 0.5,
                    anchor: target.isMe ? .bottomTrailing : .bottomLeading
                )
                .opacity(appeared ? 1 : 0)
                .position(
                    x: target.isMe
                        ? (source.maxX - reactionBarWidthEstimate / 2)
                        : (source.minX + reactionBarWidthEstimate / 2),
                    y: (desiredBarTop + reactionBarHeight / 2) + shift + dragOffset
                )

                // Action list — below the bubble, anchored to the
                // bubble's trailing or leading edge.
                actionListContainer
                    .frame(maxWidth: 240, alignment: target.isMe ? .trailing : .leading)
                    .heightReader($actionListHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(
                        appeared ? 1 : 0.7,
                        anchor: target.isMe ? .topTrailing : .topLeading
                    )
                    .opacity(appeared ? 1 : 0)
                    .position(
                        x: target.isMe
                            ? (source.maxX - 120)
                            : (source.minX + 120),
                        y: (desiredActionsTop + actionListHeight / 2) + shift + dragOffset
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }

    private var reactionBarWidthEstimate: CGFloat {
        // 8 emojis (38pt each) + chevron (32pt) + padding — good enough
        // for anchoring. The bar self-sizes; we just need a stable
        // anchor point for position().
        CGFloat(8 * 38 + 32 + 16)
    }

    @ViewBuilder
    private var actionListContainer: some View {
        VStack(spacing: 0) { actions() }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
            appeared = false
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            onDismiss()
        }
    }
}

/// Single row in the message menu action list.
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

/// Reads the view's height into a Binding via a PreferenceKey. Scoped
/// to this file since the menu overlay is the only consumer.
private struct HeightPrefKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func heightReader(_ binding: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: HeightPrefKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(HeightPrefKey.self) { binding.wrappedValue = $0 }
    }
}
