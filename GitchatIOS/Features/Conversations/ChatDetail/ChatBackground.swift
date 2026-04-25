import SwiftUI

/// Subtle Telegram-style background for the chat detail view.
/// A soft accent-tinted gradient with a faint dotted pattern overlay,
/// rendered behind the message list. Adapts to light/dark mode via
/// system colors so it never fights the bubble palette.
struct ChatBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color("ChatBackground"),
                    Color("AccentColor").opacity(colorScheme == .dark ? 0.06 : 0.04),
                    Color("ChatBackground"),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Faint dotted pattern overlay for texture.
            Canvas { context, size in
                let dot: CGFloat = 1.5
                let spacing: CGFloat = 22
                let color = Color("AccentColor").opacity(colorScheme == .dark ? 0.05 : 0.04)
                let stroke = GraphicsContext.Shading.color(color)
                var y: CGFloat = 8
                var row = 0
                while y < size.height {
                    let xOffset: CGFloat = (row % 2 == 0) ? 0 : spacing / 2
                    var x: CGFloat = 8 + xOffset
                    while x < size.width {
                        let rect = CGRect(x: x, y: y, width: dot, height: dot)
                        context.fill(Path(ellipseIn: rect), with: stroke)
                        x += spacing
                    }
                    y += spacing
                    row += 1
                }
            }
            .allowsHitTesting(false)
        }
    }
}
