import SwiftUI

struct GlassPill: ViewModifier {
    // Using a rounded rectangle with a fixed max corner radius so the
    // capsule stays pretty when the text field grows to multiple lines.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}
