import SwiftUI
import Toasts

/// Global toast surface.
///
/// Back when this was a homemade capsule the subtitle line could run
/// past the screen edge (the capsule was `.fixedSize(horizontal: true)`
/// which grows a fixed-height pill until it overflows). Now we bridge
/// the existing `ToastCenter.shared.show(...)` call sites — scattered
/// through services, view models, and async closures — to the
/// `swiftui-toasts` library, which handles wrapping, safe area,
/// swipe-to-dismiss, VoiceOver, and dark mode for us.
///
/// The old API is preserved verbatim so this swap is a zero-call-site
/// change: `ToastCenter.shared.show(.success, "Title", "Subtitle")`
/// still works. Title/subtitle collapse into the library's single
/// `message` field (joined with a newline) because the library's
/// built-in layout already gives correct hierarchy via line breaks
/// and word wrapping — no need for our own two-line VStack.

struct Toast: Identifiable, Equatable {
    enum Kind: Equatable {
        case success, info, warning, error
        var systemImage: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String?
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    /// Fresh envelope on every `show()` so publishing the same toast
    /// twice in a row still fires `.onReceive` (a raw `Toast?` with
    /// the same title/subtitle would be Equatable-equal and dedup'd).
    struct Pending: Identifiable {
        let id = UUID()
        let toast: Toast
    }

    @Published var pending: Pending?

    private init() {}

    func show(_ kind: Toast.Kind, _ title: String, _ subtitle: String? = nil) {
        Haptics.notify(kind)
        pending = Pending(toast: Toast(kind: kind, title: title, subtitle: subtitle))
    }
}

struct ToastHostModifier: ViewModifier {
    func body(content: Content) -> some View {
        // `.installToast` injects the library's `\.presentToast`
        // environment value into its *content*. So the bridge view has
        // to be nested inside `installToast` to read that environment —
        // applying the modifier further out would leave the bridge
        // reading a no-op default handler.
        ToastBridge { content }
            .installToast(position: .top)
    }
}

private struct ToastBridge<Content: View>: View {
    @ObservedObject private var center = ToastCenter.shared
    @Environment(\.presentToast) private var presentToast
    let content: () -> Content

    init(@ViewBuilder _ content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .onReceive(center.$pending.compactMap { $0 }) { pending in
                let t = pending.toast
                let message: String
                if let sub = t.subtitle, !sub.isEmpty {
                    message = "\(t.title)\n\(sub)"
                } else {
                    message = t.title
                }
                presentToast(ToastValue(
                    icon: Image(systemName: t.kind.systemImage),
                    message: message
                ))
            }
    }
}

extension View {
    func toastHost() -> some View { modifier(ToastHostModifier()) }
}
