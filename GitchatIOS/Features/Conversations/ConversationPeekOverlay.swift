import SwiftUI
import UIKit

/// Telegram/Messenger-style peek for a conversation row. Lives in a
/// dedicated overlay UIWindow (see `PeekHostWindow`) so the blur
/// covers the tab bar and nav bar — same architecture Telegram-iOS
/// uses for `ContextControllerImpl`.
struct ConversationPeekOverlay: View {
    let conversation: Conversation
    let myLogin: String?
    let actions: [PeekMenuAction]
    let onCommit: () -> Void
    let onDismiss: () -> Void

    // Telegram values (extracted from ContextControllerImpl &
    // ContextControllerExtractedPresentationNode):
    //   - card + menu spring: duration 0.42, damping 104 (POP)
    //     ≈ SwiftUI .spring(response: 0.42, dampingFraction: 0.82)
    //   - backdrop fade-in: 0.20s easeInOut
    //   - dismiss: 0.20s easeInOut (NOT spring)
    //   - drag rubber-band: overscroll * 0.35
    // — except: Telegram's 0.35 is for in-scrollview overscroll,
    // which feels intentionally laggy. For a dismiss drag a near
    // 1:1 follow feels much snappier (matches Photos / Messenger).
    // Use 0.9 + threshold 90 so the card tracks the finger almost
    // exactly and commits with a small motion.
    private static let presentSpring: Animation = .spring(response: 0.42, dampingFraction: 0.82)
    private static let backdropFade: Animation = .easeInOut(duration: 0.20)
    private static let dismissTiming: Animation = .easeInOut(duration: 0.20)
    private static let dragFollow: CGFloat = 0.9

    @State private var appeared = false
    @State private var rawDrag: CGFloat = 0

    private let dismissThreshold: CGFloat = 90

    /// Near 1:1 finger tracking — the card moves with the finger
    /// instead of dragging behind it.
    private var dragOffset: CGFloat {
        rawDrag * Self.dragFollow
    }

    private var dragProgress: Double {
        Double(min(1, abs(dragOffset) / dismissThreshold))
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                preview
                menu
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .offset(y: dragOffset)
            .scaleEffect(appeared ? 1 : 0.86, anchor: .center)
            .opacity(appeared ? 1 - dragProgress * 0.4 : 0)
        }
        .onAppear {
            withAnimation(Self.presentSpring) {
                appeared = true
            }
        }
    }

    private var backdrop: some View {
        PeekBlurBackdrop()
            .ignoresSafeArea()
            .opacity(appeared ? 1 - dragProgress * 0.85 : 0)
            .animation(Self.backdropFade, value: appeared)
            .contentShape(Rectangle())
            .onTapGesture { dismissAnimated() }
    }

    private var preview: some View {
        ConversationHoldPreview(
            conversation: conversation,
            myLogin: myLogin
        )
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onTapGesture { commitAnimated() }
    }

    private var menu: some View {
        VStack(spacing: 0) {
            ForEach(actions.indices, id: \.self) { i in
                let a = actions[i]
                Button {
                    runAction(a)
                } label: {
                    HStack {
                        Text(a.title)
                            .foregroundStyle(a.isDestructive ? Color.red : Color(.label))
                        Spacer(minLength: 12)
                        Image(systemName: a.systemImage)
                            .foregroundStyle(a.isDestructive ? Color.red : Color(.label))
                    }
                    .font(.system(size: 16))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < actions.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 260)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                rawDrag = value.translation.height
            }
            .onEnded { value in
                if abs(value.translation.height) > dismissThreshold {
                    dismissAnimated()
                } else {
                    withAnimation(Self.presentSpring) {
                        rawDrag = 0
                    }
                }
            }
    }

    private func dismissAnimated() {
        withAnimation(Self.dismissTiming) {
            appeared = false
            rawDrag = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            onDismiss()
        }
    }

    private func commitAnimated() {
        withAnimation(Self.dismissTiming) {
            appeared = false
            rawDrag = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            onDismiss()
            onCommit()
        }
    }

    private func runAction(_ a: PeekMenuAction) {
        // Selection haptic when picking a menu item — matches
        // Telegram's `UISelectionFeedbackGenerator.selectionChanged()`.
        Haptics.selection()
        withAnimation(Self.dismissTiming) {
            appeared = false
            rawDrag = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            onDismiss()
            a.handler()
        }
    }
}

struct PeekMenuAction {
    let title: String
    let systemImage: String
    let isDestructive: Bool
    let handler: () -> Void

    init(
        title: String,
        systemImage: String,
        isDestructive: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = isDestructive
        self.handler = handler
    }
}

private struct PeekBlurBackdrop: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}
