import SwiftUI
import UniformTypeIdentifiers

/// Drag-and-drop image receiver + hover overlay. Enabled on iPad and
/// Mac Catalyst — the two platforms where dragging between apps is a
/// first-class gesture. iPhone: `.onDrop` still registers (cheap) so
/// Split View drops work, but the visual overlay is gated to iPad /
/// Catalyst to avoid a rarely-useful affordance cluttering a phone.
///
/// Lives as its own modifier to keep `ChatDetailView.chatBody`'s
/// type-check budget under Swift's ceiling.
struct CatalystDropModifier<Overlay: View>: ViewModifier {
    @Binding var isDragOver: Bool
    let dragOverlay: Overlay
    let onDrop: ([NSItemProvider]) -> Void

    private var showsOverlay: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    func body(content: Content) -> some View {
        content
            .overlay { if showsOverlay { dragOverlay } }
            .animation(.easeInOut(duration: 0.15), value: isDragOver)
            .onDrop(
                // Broadened the accepted UTI set — some drag sources
                // (Safari image drags, Messages, Finder) expose the
                // payload under `public.data` or `public.url` instead
                // of `public.image`. Accept all of them; `handleDrop`
                // filters to what it can actually decode.
                of: [
                    UTType.image.identifier,
                    UTType.fileURL.identifier,
                    UTType.url.identifier,
                    UTType.data.identifier,
                    "public.jpeg",
                    "public.png",
                    "public.heic",
                ],
                isTargeted: showsOverlay ? $isDragOver : .constant(false)
            ) { providers in
                #if DEBUG
                print("[drop] providers=\(providers.count) types=\(providers.flatMap { $0.registeredTypeIdentifiers })")
                #endif
                onDrop(providers)
                return true
            }
    }
}
