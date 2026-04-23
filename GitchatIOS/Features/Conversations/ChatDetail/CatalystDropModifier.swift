import SwiftUI
import UniformTypeIdentifiers

/// Catalyst-only drag-and-drop + paste-image handling, extracted into
/// its own modifier so `ChatDetailView.chatBody`'s modifier chain stays
/// under Swift's type-checker budget on Catalyst (the extra .overlay /
/// .onDrop / .onPasteCommand on top of the already-long sheet chain
/// pushes the expression over the limit).
struct CatalystDropModifier<Overlay: View>: ViewModifier {
    @Binding var isDragOver: Bool
    let dragOverlay: Overlay
    let onDrop: ([NSItemProvider]) -> Void

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        // Note: `onPasteCommand` is macOS-only in SwiftUI — Catalyst
        // doesn't expose it. Paste-image on Catalyst is handled
        // elsewhere (UIKit responder chain); here we only register the
        // drag-and-drop overlay.
        content
            .overlay { dragOverlay }
            .animation(.easeInOut(duration: 0.15), value: isDragOver)
            .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: $isDragOver) { providers in
                onDrop(providers)
                return true
            }
        #else
        content
        #endif
    }
}
