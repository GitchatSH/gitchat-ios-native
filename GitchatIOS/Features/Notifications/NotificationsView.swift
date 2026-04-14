import SwiftUI

@MainActor
final class NotificationsViewModel: ObservableObject {
    @Published var items: [Notification] = []
    @Published var isLoading = false

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
                        HStack(spacing: 12) {
                            AvatarView(url: n.actor_avatar_url, size: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(notifText(n)).font(.subheadline)
                                if let preview = n.metadata?.preview {
                                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            if !n.is_read {
                                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                            }
                        }
                    }
                    .listStyle(.plain)
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
