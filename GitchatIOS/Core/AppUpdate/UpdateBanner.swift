import SwiftUI

struct UpdateBanner: View {
    let versionRaw: String
    let notes: String?
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("New version \(versionRaw) available")
                    .font(.subheadline.weight(.semibold))
                if let notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button("Update", action: onUpdate)
                .font(.callout.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss update banner")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

#Preview {
    UpdateBanner(
        versionRaw: "1.4.2",
        notes: "Faster message search and fixes for muted chats.",
        onUpdate: {},
        onDismiss: {}
    )
}
