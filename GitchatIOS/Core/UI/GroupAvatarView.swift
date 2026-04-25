import SwiftUI

/// Single rounded-square avatar for group conversations.
/// Shows group_avatar_url if available, otherwise first letter on gradient background.
struct GroupAvatarView: View {
    let name: String?
    let avatarURL: String?
    let groupId: String
    let size: CGFloat

    private static let gradients: [(Color, Color)] = [
        (Color(red: 1.0, green: 0.53, blue: 0.37), Color(red: 1.0, green: 0.32, blue: 0.42)),
        (Color(red: 1.0, green: 0.82, blue: 0.34), Color(red: 1.0, green: 0.62, blue: 0.18)),
        (Color(red: 0.55, green: 0.86, blue: 0.51), Color(red: 0.24, green: 0.78, blue: 0.40)),
        (Color(red: 0.38, green: 0.83, blue: 0.89), Color(red: 0.24, green: 0.63, blue: 0.90)),
        (Color(red: 0.44, green: 0.70, blue: 0.94), Color(red: 0.36, green: 0.56, blue: 0.94)),
        (Color(red: 0.83, green: 0.54, blue: 0.90), Color(red: 0.72, green: 0.42, blue: 0.84)),
        (Color(red: 0.94, green: 0.52, blue: 0.61), Color(red: 0.90, green: 0.41, blue: 0.60)),
    ]

    /// Deterministic hash (djb2) so gradient color is stable across app launches.
    private var gradient: (Color, Color) {
        var hash: UInt64 = 5381
        for byte in groupId.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let idx = Int(hash % UInt64(Self.gradients.count))
        return Self.gradients[idx]
    }

    private var initial: String {
        guard let name, let first = name.first else { return "#" }
        return String(first).uppercased()
    }

    private var cornerRadius: CGFloat { size * (16.0 / 56.0) }

    var body: some View {
        if let avatarURL, let url = URL(string: avatarURL) {
            CachedAsyncImage(url: url, contentMode: .fill, maxPixelSize: size * 3)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .accessibilityHidden(true)
        } else {
            let g = gradient
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [g.0, g.1], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay {
                    Text(initial)
                        .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
        }
    }
}
