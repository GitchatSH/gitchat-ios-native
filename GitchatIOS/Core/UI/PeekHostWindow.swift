import SwiftUI
import UIKit

/// Window-level overlay host. The peek covers the entire scene
/// including the tab bar and nav bar by living in its own UIWindow
/// at `.alert + 1`. This is what Telegram does — their context
/// controller is a Display-framework view controller hosted in an
/// overlay window above the main interface.
@MainActor
final class PeekHostWindow {
    static let shared = PeekHostWindow()

    private var window: UIWindow?

    /// Show a SwiftUI overlay covering the whole scene. Subsequent
    /// calls replace the previous overlay.
    func present<Content: View>(@ViewBuilder _ content: () -> Content) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }

        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.isOpaque = false

        // Plain UIWindow — peek absorbs all touches by design.
        // SwiftUI's gesture system inside the host view resolves
        // taps on the backdrop (→ dismiss), card (→ commit), and
        // menu items normally. We don't pass touches through to
        // the app underneath because while peek is active every
        // touch should belong to peek interactions only.
        let w = UIWindow(windowScene: scene)
        w.backgroundColor = .clear
        w.isOpaque = false
        w.windowLevel = .alert + 1
        w.rootViewController = host
        w.makeKeyAndVisible()
        self.window = w
    }

    func dismiss() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }
}
