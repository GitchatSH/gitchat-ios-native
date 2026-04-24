import SwiftUI

/// Tahoe-style frosted capsule background used by Catalyst's floating
/// pills (bottom nav, chat composer). Keeps the two pills visually
/// identical so they read as one horizontal row across the split view.
///
/// - iOS 26+: `glassEffect(.regular)` — liquid glass
/// - Fallback: `ultraThinMaterial` + hairline stroke + shadow
struct MacFloatingPill: ViewModifier {
    private var shape: Capsule { Capsule(style: .continuous) }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 6)
        }
    }
}

extension View {
    /// Apply the shared Catalyst floating-pill background.
    func macFloatingPill() -> some View {
        self.modifier(MacFloatingPill())
    }
}
