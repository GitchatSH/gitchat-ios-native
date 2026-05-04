import SwiftUI

/// Tahoe-style frosted rounded background used by Catalyst's floating
/// pills (bottom nav, chat composer). Keeps the two pills visually
/// identical so they read as one horizontal row across the split view.
///
/// Uses a fixed-radius `RoundedRectangle` (28pt, continuous) rather
/// than `Capsule` so the composer keeps a soft, consistent corner
/// when it grows multi-line — capsule would stretch the end caps
/// proportionally to height, which reads as a giant ellipse instead
/// of a card. The 28pt value equals half the 1-line composer/nav
/// height (44pt button + 6pt × 2 vertical padding = 56pt) so single-
/// line surfaces still read as a true capsule.
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
