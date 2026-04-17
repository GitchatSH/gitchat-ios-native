import SwiftUI

@MainActor
final class NotificationsViewModel: ObservableObject {
    @Published var items: [Notification] = []
    @Published var locallyRead: Set<String> = []
    @Published var isSyncing = false

    func isRead(_ n: Notification) -> Bool {
        n.is_read || locallyRead.contains(n.id)
    }

    func markReadLocally(_ id: String) {
        locallyRead.insert(id)
    }

    func load() async {
        isSyncing = true
        let start = Date()
        do {
            let resp = try await APIClient.shared.notifications()
            self.items = resp.data
        } catch { }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 2 {
            try? await Task.sleep(nanoseconds: UInt64((2 - elapsed) * 1_000_000_000))
        }
        isSyncing = false
    }

    func markAllRead() async {
        try? await APIClient.shared.markNotificationsRead(all: true)
        await load()
    }
}

struct NotificationsView: View {
    @StateObject private var vm = NotificationsViewModel()
    @EnvironmentObject var socket: SocketClient
    @EnvironmentObject var auth: AuthStore
    @State private var sheetProfile: String?
    @State private var sheetConversation: Conversation?

    private var visible: [Notification] {
        vm.items.filter { n in
            // Hide self-notifications and rows with no renderable
            // action text — those are usually backend bugs and just
            // confuse the user.
            guard n.actor_login != auth.login else { return false }
            return !notifText(n).trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if visible.isEmpty && !vm.isSyncing {
                    ContentUnavailableCompat(
                        title: "No notifications",
                        systemImage: "bell",
                        description: "Follows, mentions, and messages land here."
                    )
                } else {
                    List(visible) { n in
                        Button {
                            // Hide the orange dot immediately.
                            vm.markReadLocally(n.id)
                            // Fire-and-forget backend mark.
                            Task { try? await APIClient.shared.markNotificationsRead(ids: [n.id]) }
                            route(for: n)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(
                                    // Always use github.com/<login>.png
                                    // — the backend has been seen to
                                    // store the wrong actor_avatar_url
                                    // for some notifications, which
                                    // resulted in arthurbijan showing
                                    // leeknowsai's face.
                                    url: "https://github.com/\(n.actor_login).png",
                                    size: 40,
                                    login: n.actor_login
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    notifLabel(n).font(.subheadline)
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
                        .listRowBackground(
                            vm.isRead(n)
                                ? Color.clear
                                : Color.accentColor.opacity(0.06)
                        )
                    }
                    .listStyle(.plain)
                    #if !targetEnvironment(macCatalyst)
            .scrollIndicators(.hidden)
            #endif
                    .refreshable { await vm.load() }
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if vm.isSyncing {
                        SyncingIndicator()
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Read all") {
                        Task {
                            await vm.markAllRead()
                            ToastCenter.shared.show(.success, "All marked as seen")
                        }
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.isSyncing)
            .task {
                await vm.load()
                socket.onNotificationNew = { Task { await vm.load() } }
            }
            .onAppear {
                Task { await vm.load() }
            }
            .sheet(item: Binding<ProfileLoginRoute?>(
                get: { sheetProfile.map(ProfileLoginRoute.init) },
                set: { sheetProfile = $0?.login }
            )) { route in
                NavigationStack { ProfileView(login: route.login) }
            }
            .sheet(item: $sheetConversation) { convo in
                NavigationStack {
                    ChatDetailView(conversation: convo)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Done") { sheetConversation = nil }
                            }
                        }
                }
            }
        }
    }

    private func route(for n: Notification) {
        Haptics.selection()
        switch n.type {
        case "new_message", "chat_message", "mention":
            if let id = n.metadata?.conversationId, !id.isEmpty {
                Task {
                    let resp = try? await APIClient.shared.listConversations(limit: 100)
                    if let convo = resp?.conversations.first(where: { $0.id == id }) {
                        sheetConversation = convo
                    } else {
                        sheetProfile = n.actor_login
                    }
                }
            } else {
                sheetProfile = n.actor_login
            }
        default:
            sheetProfile = n.actor_login
        }
    }

    private func notifText(_ n: Notification) -> String {
        switch n.type {
        case "new_message": return "\(n.actor_login) sent you a message"
        case "mention": return "\(n.actor_login) mentioned you"
        case "follow": return "\(n.actor_login) followed you"
        case "repo_activity": return "\(n.actor_login) in \(n.metadata?.repoFullName ?? "a repo")"
        case "wave": return "\(n.actor_login) waved 👋"
        default: return ""
        }
    }

    private func notifLabel(_ n: Notification) -> Text {
        let login = Text(n.actor_login).bold().foregroundColor(Color(.label))
        switch n.type {
        case "new_message":
            return login + Text(" sent you a message").foregroundColor(Color(.label))
        case "mention":
            return login + Text(" mentioned you").foregroundColor(Color(.label))
        case "follow":
            return login + Text(" followed you").foregroundColor(Color(.label))
        case "repo_activity":
            return login + Text(" in \(n.metadata?.repoFullName ?? "a repo")").foregroundColor(Color(.label))
        case "wave":
            return login + Text(" waved 👋").foregroundColor(Color(.label))
        default:
            return Text("")
        }
    }
}
