import SwiftUI

struct InstantTooltip: ViewModifier {
    let text: String
    @State private var hovering = false

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .overlay(alignment: .top) {
                if hovering && !text.isEmpty {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                        .offset(y: -26)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(999)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.1), value: hovering)
        #else
        content
        #endif
    }
}

extension View {
    func instantTooltip(_ text: String) -> some View {
        modifier(InstantTooltip(text: text))
    }
}
