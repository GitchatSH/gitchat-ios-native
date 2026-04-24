import SwiftUI

/// Custom bottom navigation strip for the Catalyst sidebar.
/// Renders 5 icons (Chats, Discover, Activity, Friends, Me) with hover
/// affordance, tooltip, badge, and active accent color + pill highlight.
struct MacBottomNav: View {
    @Binding var selectedTab: Int
    var unreadChats: Int = 0
    var unreadActivity: Int = 0

    private let items: [Item] = [
        .init(tag: 0, title: "Chats",    icon: .asset("ChatTabIcon")),
        .init(tag: 1, title: "Discover", icon: .symbol("safari.fill")),
        .init(tag: 2, title: "Activity", icon: .symbol("bell.fill")),
        .init(tag: 3, title: "Friends",  icon: .symbol("person.2.fill")),
        .init(tag: 4, title: "Me",       icon: .symbol("person.crop.circle.fill")),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                iconButton(for: item)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .macFloatingPill()
        .padding(.bottom, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func iconButton(for item: Item) -> some View {
        let isActive = selectedTab == item.tag
        let badgeCount = badgeCount(for: item.tag)

        Button {
            if selectedTab != item.tag {
                selectedTab = item.tag
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                iconImage(for: item, isActive: isActive)
                    .frame(width: 60, height: 44)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())

                if badgeCount > 0 {
                    badgeView(count: badgeCount)
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .clipShape(Capsule(style: .continuous))
        .macHover()
        .instantTooltip(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private func iconImage(for item: Item, isActive: Bool) -> some View {
        let tint = isActive ? Color.accentColor : Color.primary.opacity(0.75)
        switch item.icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(tint)
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private func badgeView(count: Int) -> some View {
        let label = count > 99 ? "99+" : "\(count)"
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 16)
            .background(Color.red, in: Capsule())
    }

    private func badgeCount(for tag: Int) -> Int {
        switch tag {
        case 0: return unreadChats
        case 2: return unreadActivity
        default: return 0
        }
    }

    private struct Item: Identifiable {
        let tag: Int
        let title: String
        let icon: IconSource
        var id: Int { tag }
    }

    private enum IconSource {
        case symbol(String)
        case asset(String)
    }
}

#if DEBUG
private struct MacBottomNavPreviewHost: View {
    @State var tab: Int
    var unreadChats: Int
    var unreadActivity: Int

    var body: some View {
        VStack(spacing: 0) {
            Color(.systemBackground)
                .overlay(Text("Sidebar content above").foregroundStyle(.secondary))
            MacBottomNav(
                selectedTab: $tab,
                unreadChats: unreadChats,
                unreadActivity: unreadActivity
            )
        }
        .frame(width: 320, height: 380)
    }
}

#Preview("Default — Chats active") {
    MacBottomNavPreviewHost(tab: 0, unreadChats: 0, unreadActivity: 0)
}

#Preview("Activity active + badges") {
    MacBottomNavPreviewHost(tab: 2, unreadChats: 12, unreadActivity: 3)
}

#Preview("Heavy unread") {
    MacBottomNavPreviewHost(tab: 0, unreadChats: 142, unreadActivity: 99)
}
#endif
