import SwiftUI

/// Decorative bubble tail — drawn as overlay, NOT used for clipping.
/// The tail appears only on the LAST message in a same-sender group.
struct BubbleTailOverlay: View {
    let isOutgoing: Bool
    let color: Color

    var body: some View {
        BubbleTailShape(isOutgoing: isOutgoing)
            .fill(color)
            .frame(width: 12, height: 8)
    }
}

struct BubbleTailShape: Shape {
    let isOutgoing: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isOutgoing {
            path.move(to: CGPoint(x: 0, y: 0))
            path.addCurve(
                to: CGPoint(x: rect.width, y: rect.height),
                control1: CGPoint(x: 4, y: rect.height * 0.3),
                control2: CGPoint(x: rect.width, y: rect.height * 0.5)
            )
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        } else {
            path.move(to: CGPoint(x: rect.width, y: 0))
            path.addCurve(
                to: CGPoint(x: 0, y: rect.height),
                control1: CGPoint(x: rect.width - 4, y: rect.height * 0.3),
                control2: CGPoint(x: 0, y: rect.height * 0.5)
            )
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}
