import SwiftUI

/// On Mac Catalyst (desktop), intercept the Return key on the composer:
/// - plain Return → call onSend()
/// - Shift+Return → fall through so the TextField inserts a newline
///
/// On iOS this is a no-op — the soft keyboard's Return key just
/// inserts a newline as normal, matching standard chat apps.
struct DesktopReturnToSend: ViewModifier {
    let onSend: () -> Void

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        if #available(iOS 17.0, *) {
            content.onKeyPress(keys: [.return]) { press in
                if press.modifiers.contains(.shift) {
                    // Let the TextField handle the newline itself.
                    return .ignored
                }
                onSend()
                return .handled
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
