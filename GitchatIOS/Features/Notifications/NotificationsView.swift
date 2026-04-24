import SwiftUI

enum NotificationFilter: String, CaseIterable, Identifiable {
    case all
    case messages
    case mentions
    case follows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .messages: return "Messages"
        case .mentions: return "Mentions"
        case .follows: return "Follows"
        }
    }

    func matches(_ n: Notification) -> Bool {
        switch self {
        case .all: return true
        case .messages: return n.type == "new_message" || n.type == "chat_message" || n.type == "reply"
        case .mentions: return n.type == "mention"
        case .follows: return n.type == "follow" || n.type == "wave"
        }
    }
}

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

    func unreadCount(filter: NotificationFilter) -> Int {
        items.filter { filter.matches($0) && !isRead($0) }.count
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

    func markAllRead(filter: NotificationFilter = .all) async {
        let targetIds = items.filter { filter.matches($0) && !isRead($0) }.map(\.id)
        for id in targetIds { locallyRead.insert(id) }
        if filter == .all {
            try? await APIClient.shared.markNotificationsRead(all: true)
        } else if !targetIds.isEmpty {
            try? await APIClient.shared.markNotificationsRead(ids: targetIds)
        }
        await load()
    }
}

struct NotificationsView: View {
    @StateObject private var vm = NotificationsViewModel()
    @EnvironmentObject var socket: SocketClient
    @EnvironmentObject var auth: AuthStore
    @State private var sheetProfile: String?
    @State private var sheetConversation: Conversation?
    @State private var filter: NotificationFilter = .all

    private var visible: [Notification] {
        vm.items.filter { n in
            guard n.actor_login != auth.login else { return false }
            guard filter.matches(n) else { return false }
            return !notifText(n).trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $filter) {
                    ForEach(NotificationFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Group {
                    if visible.isEmpty && !vm.isSyncing {
                        ContentUnavailableCompat(
                            title: emptyTitle,
                            systemImage: emptyIcon,
                            description: "Follows, mentions, and messages land here."
                        )
                    } else {
                        List(visible) { n in
                            Button {
                                vm.markReadLocally(n.id)
                                Task { try? await APIClient.shared.markNotificationsRead(ids: [n.id]) }
                                route(for: n)
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarView(
                                        url: "https://github.com/\(n.actor_login).png",
                                        size: macRowAvatarSize,
                                        login: n.actor_login
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        notifLabel(n).font(macRowTitleFont)
                                        if let preview = n.metadata?.preview {
                                            Text(preview).font(macRowSubtitleFont).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Text(RelativeTime.format(n.created_at))
                                            .font(macRowMetaFont)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if !vm.isRead(n) {
                                        Circle().fill(Color("AccentColor")).frame(width: 8, height: 8)
                                    }
                                }
                                .contentShape(Rectangle())
                                #if targetEnvironment(macCatalyst)
                                .padding(.horizontal, macRowHorizontalPadding)
                                .padding(.vertical, macRowVerticalPadding)
                                #endif
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            #if targetEnvironment(macCatalyst)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            #endif
                            .hideMacScrollIndicators()
                            .listRowBackground(
                                vm.isRead(n)
                                    ? Color.clear
                                    : Color("AccentColor").opacity(0.06)
                            )
                        }
                        .listStyle(.plain)
                        .macRowListContainer()
                        .scrollIndicators(.hidden, axes: .vertical)
                        .refreshable { await vm.load() }
                    }
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(filter == .all ? "Read all" : "Mark seen") {
                        Task {
                            await vm.markAllRead(filter: filter)
                            ToastCenter.shared.show(.success, filter == .all ? "All marked as seen" : "\(filter.title) marked as seen")
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

    private var emptyTitle: String {
        switch filter {
        case .all: return "No notifications"
        case .messages: return "No messages"
        case .mentions: return "No mentions"
        case .follows: return "No follows"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .all: return "bell"
        case .messages: return "bubble.left"
        case .mentions: return "at"
        case .follows: return "person.2"
        }
    }

    private func route(for n: Notification) {
        Haptics.selection()
        switch n.type {
        case "new_message", "chat_message", "mention", "reply":
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
        case "new_message", "chat_message": return "\(n.actor_login) sent you a message"
        case "reply": return "\(n.actor_login) replied to your message"
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
        case "new_message", "chat_message":
            return login + Text(" sent you a message").foregroundColor(Color(.label))
        case "reply":
            return login + Text(" replied to your message").foregroundColor(Color(.label))
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
