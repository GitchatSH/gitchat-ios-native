import SwiftUI

/// Tahoe-style frosted rounded-rectangle background used by Catalyst's
/// floating pills (bottom nav, chat composer). Keeps the two pills
/// visually identical so they read as one horizontal row across the
/// split view.
///
/// Uses `RoundedRectangle(cornerRadius: 28)` rather than `Capsule` so
/// that when the composer grows multi-line the shape keeps four evenly
/// rounded corners with flat vertical sides, instead of stretching the
/// left/right semicircle ends taller. At the standard single-row pill
/// height (44pt button + 6pt vertical padding × 2 = 56pt), 28pt radius
/// equals half-height and visually matches the prior capsule.
///
/// - iOS 26+: `glassEffect(.regular)` — liquid glass
/// - Fallback: `ultraThinMaterial` + hairline stroke + shadow
struct MacFloatingPill: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
    }

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
