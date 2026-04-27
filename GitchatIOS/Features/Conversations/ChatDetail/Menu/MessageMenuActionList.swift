import SwiftUI

/// Sectioned action list for the message long-press menu.
/// Section 1: Seen by (inline avatar stack, no icon)
/// Section 2: Actions (reply, copy, pin, forward…)
/// Section 3: Danger actions (report, unsend, delete…)
struct MessageMenuActionList: View {
    @Environment(\.chatTheme) private var theme

    let actions: [MessageMenuAction]
    let seenCount: Int
    let seenLogins: [String]
    let participants: [ConversationParticipant]
    let onAction: (MessageMenuAction) -> Void

    private var normalActions: [MessageMenuAction] {
        actions.filter { !$0.isDestructive && $0 != .seenBy }
    }

    private var dangerActions: [MessageMenuAction] {
        actions.filter { $0.isDestructive }
    }

    private var showSeenBy: Bool {
        actions.contains(.seenBy)
    }

    var body: some View {
        sectionContainer {
            // Section 1: Seen by
            if showSeenBy {
                seenByRow
                sectionDivider
            }

            // Section 2: Normal actions
            ForEach(Array(normalActions.enumerated()), id: \.element) { idx, action in
                actionRow(action: action)
                if idx < normalActions.count - 1 {
                    rowDivider
                }
            }

            // Section 3: Danger actions
            if !dangerActions.isEmpty {
                sectionDivider
                ForEach(Array(dangerActions.enumerated()), id: \.element) { idx, action in
                    actionRow(action: action)
                    if idx < dangerActions.count - 1 {
                        rowDivider
                    }
                }
            }
        }
    }

    /// Thin divider between rows in same section
    private var rowDivider: some View {
        Divider().foregroundStyle(theme.menuDivider.opacity(0.25))
            .padding(.leading, 44)
    }

    /// Thicker divider between sections
    private var sectionDivider: some View {
        Divider().foregroundStyle(theme.menuDivider.opacity(0.4))
    }

    // MARK: - Seen by section

    @ViewBuilder
    private var seenByRow: some View {
        if seenCount > 0 {
            HStack(spacing: 8) {
                seenAvatarStack
                VStack(alignment: .leading, spacing: 1) {
                    Text("Seen by")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text(seenNamesList)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            HStack {
                Text("No one has seen this yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var seenNamesList: String {
        let names: [String] = seenLogins.prefix(5).map { login in
            participants.first(where: { $0.login == login })?.name ?? login
        }
        let extra = seenCount - names.count
        if extra > 0 {
            return names.joined(separator: ", ") + " +\(extra)"
        }
        return names.joined(separator: ", ")
    }

    @ViewBuilder
    private var seenAvatarStack: some View {
        let shown = min(seenCount, 3)
        let extra = seenCount - shown
        HStack(spacing: -6) {
            ForEach(0..<shown, id: \.self) { i in
                let login = i < seenLogins.count ? seenLogins[i] : nil
                let avatarURL = login.flatMap { l in
                    participants.first(where: { $0.login == l })?.avatar_url
                }
                AvatarView(url: avatarURL, size: 22, login: login ?? "")
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color(.tertiarySystemFill), in: Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            }
        }
    }

    // MARK: - Action row

    @ViewBuilder
    private func actionRow(action: MessageMenuAction) -> some View {
        Button { onAction(action) } label: {
            HStack(spacing: 12) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(action.isDestructive ? Color.red : .primary)
                    .frame(width: 20, alignment: .center)
                Text(action.title())
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(action.isDestructive ? Color.red : .primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section container

    @ViewBuilder
    private func sectionContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .modifier(MenuSectionBackground())
    }
}

// MARK: - Glass/material section background

private struct MenuSectionBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
                )
        }
    }
}
