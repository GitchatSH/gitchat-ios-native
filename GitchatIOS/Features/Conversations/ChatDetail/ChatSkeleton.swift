import SwiftUI

/// Placeholder view shown in chat detail while the first page of
/// messages is loading. Mimics the bubble layout so the screen doesn't
/// flash empty before content arrives.
struct ChatSkeleton: View {
    private let rows: [Row] = [
        Row(isMe: false, width: 200, lines: 2),
        Row(isMe: true,  width: 140, lines: 1),
        Row(isMe: false, width: 240, lines: 3),
        Row(isMe: true,  width: 180, lines: 1),
        Row(isMe: false, width: 160, lines: 1),
        Row(isMe: true,  width: 220, lines: 2),
        Row(isMe: false, width: 200, lines: 2),
        Row(isMe: true,  width: 120, lines: 1),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(rows.indices, id: \.self) { i in
                    bubble(rows[i])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .scrollDisabled(true)
        .shimmering()
        .allowsHitTesting(false)
    }

    private func bubble(_ row: Row) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            if row.isMe { Spacer(minLength: 60) } else {
                Circle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<row.lines, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: row.width, height: 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            if !row.isMe { Spacer(minLength: 60) }
        }
    }

    private struct Row {
        let isMe: Bool
        let width: CGFloat
        let lines: Int
    }
}
