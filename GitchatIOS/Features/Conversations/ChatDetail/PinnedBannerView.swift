import SwiftUI

struct PinnedBannerView: View {
    let pinnedMessages: [Message]
    let onTap: (Message) -> Void
    let onDismiss: () -> Void
    @State private var currentIndex = 0

    var body: some View {
        if let msg = pinnedMessages[safe: currentIndex] ?? pinnedMessages.first {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundColor(Color("AccentColor"))
                    .rotationEffect(.degrees(45))

                VStack(alignment: .leading, spacing: 0) {
                    Text("Tin ghim")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Color("AccentColor"))
                    Text(msg.content)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .frame(width: 44, height: 44)
            }
            .padding(.leading, 12)
            .background(Color(.systemBackground))
            .overlay(alignment: .bottom) {
                Divider()
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap(msg) }
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
