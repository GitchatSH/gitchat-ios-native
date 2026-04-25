import SwiftUI

struct TypingIndicatorRow: View {
    let logins: [String]
    var isGroup: Bool = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isGroup {
                if let first = logins.first {
                    AvatarView(url: "https://github.com/\(first).png", size: 32, login: first)
                } else {
                    Color.clear.frame(width: 32, height: 32)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                TypingDots()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                if isGroup, let first = logins.first {
                    Text("\(first) đang nhập...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Smooth wave of three pulsing dots driven off a wall-clock timeline
/// so the animation keeps its phase even as cells get reconfigured.
private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(opacity(for: i, at: t))
                        .scaleEffect(scale(for: i, at: t))
                }
            }
        }
    }

    private func phase(for index: Int, at time: TimeInterval) -> Double {
        // 1.2s period, staggered by 0.18s between dots.
        let period = 1.2
        let offset = Double(index) * 0.18
        let normalized = (time + offset).truncatingRemainder(dividingBy: period) / period
        // Smooth sine wave from 0 → 1 → 0.
        return 0.5 - 0.5 * cos(normalized * .pi * 2)
    }

    private func opacity(for index: Int, at time: TimeInterval) -> Double {
        0.35 + 0.55 * phase(for: index, at: time)
    }

    private func scale(for index: Int, at time: TimeInterval) -> Double {
        0.82 + 0.28 * phase(for: index, at: time)
    }
}
