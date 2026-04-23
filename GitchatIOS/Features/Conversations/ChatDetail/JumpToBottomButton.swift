import SwiftUI

/// Floating pill over the composer that jumps the conversation to the
/// most recent message. Uses the iOS 26 `.glass` button style when
/// available and falls back to an ultraThinMaterial circle on older OSes.
struct JumpToBottomButton: View {
    let action: () -> Void

    var body: some View {
        let tap: () -> Void = {
            Haptics.selection()
            action()
        }
        if #available(iOS 26.0, *) {
            Button(action: tap) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
            }
            .buttonBorderShape(.circle)
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(Color(.label))
        } else {
            Button(action: tap) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(.label))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .instantTooltip("Jump to latest")
        }
    }
}
