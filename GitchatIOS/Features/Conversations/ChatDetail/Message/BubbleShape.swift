import SwiftUI

/// Decorative bubble tail — drawn as overlay, NOT used for clipping.
/// The tail appears only on the LAST message in a same-sender group.
struct BubbleTailOverlay: View {
    let isOutgoing: Bool
    let color: Color

    var body: some View {
        BubbleTailShape(isOutgoing: isOutgoing)
            .fill(color)
            .frame(width: 16, height: 16)
    }
}

struct BubbleTailShape: Shape {
    let isOutgoing: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isOutgoing {
            // Starts at top-left, sweeps down-right, closes at bottom-left.
            path.move(to: CGPoint(x: 0, y: 0))
            path.addCurve(
                to: CGPoint(x: rect.width * 0.6, y: rect.height),
                control1: CGPoint(x: 0, y: rect.height * 0.4),
                control2: CGPoint(x: rect.width * 0.15, y: rect.height * 0.85)
            )
            path.addCurve(
                to: CGPoint(x: 0, y: rect.height * 0.6),
                control1: CGPoint(x: rect.width * 0.35, y: rect.height * 0.95),
                control2: CGPoint(x: 0, y: rect.height * 0.85)
            )
            path.closeSubpath()
        } else {
            // Mirrored: starts at top-right, sweeps down-left.
            path.move(to: CGPoint(x: rect.width, y: 0))
            path.addCurve(
                to: CGPoint(x: rect.width * 0.4, y: rect.height),
                control1: CGPoint(x: rect.width, y: rect.height * 0.4),
                control2: CGPoint(x: rect.width * 0.85, y: rect.height * 0.85)
            )
            path.addCurve(
                to: CGPoint(x: rect.width, y: rect.height * 0.6),
                control1: CGPoint(x: rect.width * 0.65, y: rect.height * 0.95),
                control2: CGPoint(x: rect.width, y: rect.height * 0.85)
            )
            path.closeSubpath()
        }
        return path
    }
}
