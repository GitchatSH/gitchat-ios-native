import SwiftUI

/// Renders the vertical action list that sits below the preview
/// bubble inside `MessageMenuOverlay`. One row per visible
/// `MessageMenuAction`, divider between rows, destructive rows
/// tinted red. Tapping a row calls `onAction` and relies on the
/// overlay to dismiss.
struct MessageMenuActionList: View {
    @Environment(\.chatTheme) private var theme

    let actions: [MessageMenuAction]
    /// Optional per-action context (e.g. seen count). Kept simple —
    /// we only need one piece of context today; fold more in if the
    /// action list grows.
    let seenCount: Int
    let onAction: (MessageMenuAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element) { (idx, action) in
                row(action: action, isLast: idx == actions.count - 1)
            }
        }
        .background(theme.menuSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.menuDivider.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
    }

    @ViewBuilder
    private func row(action: MessageMenuAction, isLast: Bool) -> some View {
        Button { onAction(action) } label: {
            HStack(spacing: 12) {
                Text(action.title(seenCount: seenCount))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(action.isDestructive ? Color.red : Color.primary)
                Spacer()
                Image(systemName: action.systemImage)
                    .foregroundStyle(action.isDestructive ? Color.red : Color.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().foregroundStyle(theme.menuDivider.opacity(0.4))
            }
        }
    }
}
