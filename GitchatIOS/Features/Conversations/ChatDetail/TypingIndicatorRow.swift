import SwiftUI

struct TypingIndicatorRow: View {
    let logins: [String]
    @State private var dotIndex = 0

    var body: some View {
        HStack(spacing: 6) {
            if let first = logins.first {
                AvatarView(url: "https://github.com/\(first).png", size: 28)
            } else {
                Color.clear.frame(width: 28, height: 28)
            }
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(dotIndex == i ? 1 : 0.3)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                dotIndex = (dotIndex + 1) % 3
            }
        }
    }
}
