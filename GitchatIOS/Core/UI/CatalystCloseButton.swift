import SwiftUI

/// On Mac Catalyst, SwiftUI sheets present as a centered floating panel
/// with no drag handle and no system close affordance — users can only
/// dismiss with ⎋ (Escape). That's invisible to most users.
///
/// This modifier adds a top-trailing `xmark` button overlay on Catalyst
/// only. It reads `\.dismiss` from the environment, so it works for any
/// sheet-presented view.
///
/// Usage — inside a sheet's root view:
/// ```swift
/// MySheetContent()
///     .catalystDismissable()
/// ```
struct CatalystDismissable: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
            .accessibilityLabel("Close")
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Adds a visible close button on Mac Catalyst sheets. No-op on iOS,
    /// which already has drag-to-dismiss.
    func catalystDismissable() -> some View {
        modifier(CatalystDismissable())
    }
}
