import SwiftUI

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        gradient: Gradient(colors: [
                            .white.opacity(0.0),
                            .white.opacity(0.45),
                            .white.opacity(0.0)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 1.5)
                    .offset(x: geo.size.width * phase)
                    .blendMode(.plusLighter)
                }
            )
            .mask(content)
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

struct SkeletonShape: View {
    var cornerRadius: CGFloat = 6
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(.secondarySystemBackground))
    }
}

struct SkeletonRow: View {
    var avatarSize: CGFloat = 48
    var showSubtitle: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(.secondarySystemBackground))
                .frame(width: avatarSize, height: avatarSize)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonShape().frame(width: 160, height: 12)
                if showSubtitle {
                    SkeletonShape().frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 10)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .shimmering()
    }
}

struct SkeletonList: View {
    var count: Int = 8
    var avatarSize: CGFloat = 48
    var showSubtitle: Bool = true

    var body: some View {
        List(0..<count, id: \.self) { _ in
            SkeletonRow(avatarSize: avatarSize, showSubtitle: showSubtitle)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
        .listStyle(.plain)
        .allowsHitTesting(false)
    }
}
