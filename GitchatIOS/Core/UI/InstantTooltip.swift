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
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
                        .fixedSize()
                        .offset(y: -34)
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
