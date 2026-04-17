import SwiftUI

struct SeenAvatarWithTooltip: View {
    let avatarURL: String?
    let name: String
    @State private var hovering = false

    var body: some View {
        AvatarView(url: avatarURL, size: 16)
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1))
            #if targetEnvironment(macCatalyst)
            .overlay(alignment: .top) {
                if hovering {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                        .offset(y: -22)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.1), value: hovering)
            #endif
    }
}
