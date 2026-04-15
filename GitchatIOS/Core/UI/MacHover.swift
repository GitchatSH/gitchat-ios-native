import SwiftUI

/// Mac Catalyst hover affordance — wraps `.hoverEffect(.highlight)`
/// only on macCatalyst so iOS builds remain untouched.
extension View {
    @ViewBuilder
    func macHover() -> some View {
        #if targetEnvironment(macCatalyst)
        if #available(iOS 17.0, *) {
            self.hoverEffect(.highlight)
        } else {
            self.hoverEffect()
        }
        #else
        self
        #endif
    }
}
