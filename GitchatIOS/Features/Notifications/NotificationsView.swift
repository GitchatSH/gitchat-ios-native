import SwiftUI

@MainActor
final class NotificationsViewModel: ObservableObject {
    @Published var items: [Notification] = []
    @Published var locallyRead: Set<String> = []
    @Published var isLoading = false

    func isRead(_ n: Notification) -> Bool {
        n.is_read || locallyRead.contains(n.id)
    }

    func markReadLocally(_ id: String) {
        locallyRead.insert(id)
    }

    func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            let resp = try await APIClient.shared.notifications()
            self.items = resp.data
        } catch { }
    }

    func markAllRead() async {
        try? await APIClient.shared.markNotificationsRead(all: true)
        await load()
    }
}

struct NotificationsView: View {
    @StateObject private var vm = NotificationsViewModel()
    @EnvironmentObject var socket: SocketClient

    var body: some View {
        NavigationStack {
            Group {
                if vm.items.isEmpty && !vm.isLoading {
                    ContentUnavailableCompat(
                        title: "No notifications",
                        systemImage: "bell",
                        description: "Follows, mentions, and messages land here."
                    )
                } else {
                    List(vm.items) { n in
                        Button {
                            // Hide the orange dot immediately.
                            vm.markReadLocally(n.id)
                            // Fire-and-forget backend mark.
                            Task { try? await APIClient.shared.markNotificationsRead(ids: [n.id]) }
                            route(for: n)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(
                                    url: n.actor_avatar_url ?? "https://github.com/\(n.actor_login).png",
                                    size: 40,
                                    login: n.actor_login
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(notifText(n)).font(.subheadline).foregroundStyle(Color(.label))
                                    if let preview = n.metadata?.preview {
                                        Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Text(RelativeTime.format(n.created_at))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if !vm.isRead(n) {
                                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.hidden)
                    .refreshable { await vm.load() }
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Read all") { Task { await vm.markAllRead() } }
                }
            }
            .task {
                await vm.load()
                socket.onNotificationNew = { Task { await vm.load() } }
            }
        }
    }

    private func route(for n: Notification) {
        Haptics.selection()
        switch n.type {
        case "new_message", "chat_message":
            if let id = n.metadata?.conversationId, !id.isEmpty {
                AppRouter.shared.openConversation(id: id)
            } else {
                AppRouter.shared.openProfile(login: n.actor_login)
            }
        case "mention":
            if let id = n.metadata?.conversationId, !id.isEmpty {
                AppRouter.shared.openConversation(id: id)
            } else {
                AppRouter.shared.openProfile(login: n.actor_login)
            }
        case "follow", "wave":
            AppRouter.shared.openProfile(login: n.actor_login)
        default:
            AppRouter.shared.openProfile(login: n.actor_login)
        }
    }

    private func notifText(_ n: Notification) -> String {
        switch n.type {
        case "new_message": return "\(n.actor_login) sent you a message"
        case "mention": return "\(n.actor_login) mentioned you"
        case "follow": return "\(n.actor_login) followed you"
        case "repo_activity": return "\(n.actor_login) in \(n.metadata?.repoFullName ?? "a repo")"
        case "wave": return "\(n.actor_login) waved 👋"
        default: return n.actor_login
        }
    }
}
