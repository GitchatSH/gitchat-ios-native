import SwiftUI
import UIKit

/// Compact chip above the composer that surfaces an image currently
/// sitting on the pasteboard (`ClipboardWatcher`). Tap → paste, X →
/// dismiss without re-prompting for this image.
struct ChatClipboardChip: View {
    let image: UIImage
    let onPaste: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text("Image in clipboard")
                    .font(.system(size: 13, weight: .semibold))
                Text("Tap to attach").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Paste", action: onPaste)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss clipboard image")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
