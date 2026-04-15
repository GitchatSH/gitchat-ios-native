import SwiftUI

extension View {
    /// On Mac Catalyst, cap the view's width to a comfortable reading
    /// width (~720pt) and center it inside the window so non-chat
    /// pages (Channels, Activity, Friends, Me) don't stretch across
    /// a wide desktop window. Pass-through on iOS.
    @ViewBuilder
    func macReadableWidth(_ maxWidth: CGFloat = 720) -> some View {
        #if targetEnvironment(macCatalyst)
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            self.frame(maxWidth: maxWidth)
            Spacer(minLength: 0)
        }
        #else
        self
        #endif
    }
}
