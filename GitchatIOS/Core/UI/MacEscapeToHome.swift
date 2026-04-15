import SwiftUI

/// Mac Catalyst: pressing Escape clears the selected conversation,
/// returning the user to the empty-detail "home" state.
struct MacEscapeToHome: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        if #available(iOS 17.0, *) {
            content.onKeyPress(.escape) {
                action()
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
