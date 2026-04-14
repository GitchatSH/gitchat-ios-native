import SwiftUI

@MainActor
final class ConversationsViewModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var isLoading = false
    @Published var error: String?

    func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            let resp = try await APIClient.shared.listConversations()
            self.conversations = resp.conversations
        } catch {
            self.error = error.localizedDescription
        }
    }

    func togglePin(_ convo: Conversation) async {
        Haptics.impact(.light)
        do {
            if convo.isPinned {
                try await APIClient.shared.unpinConversation(id: convo.id)
                ToastCenter.shared.show(.info, "Unpinned", convo.displayTitle)
            } else {
                try await APIClient.shared.pinConversation(id: convo.id)
                ToastCenter.shared.show(.success, "Pinned", convo.displayTitle)
            }
            await load()
        } catch {
            self.error = error.localizedDescription
            ToastCenter.shared.show(.error, "Couldn't pin", error.localizedDescription)
        }
    }

    func delete(_ convo: Conversation) async {
        Haptics.impact(.medium)
        do {
            try await APIClient.shared.deleteConversation(id: convo.id)
            conversations.removeAll { $0.id == convo.id }
            ToastCenter.shared.show(.warning, "Conversation deleted", convo.displayTitle)
        } catch {
            self.error = error.localizedDescription
            ToastCenter.shared.show(.error, "Couldn't delete", error.localizedDescription)
        }
    }
}

struct ConversationsListView: View {
    @StateObject private var vm = ConversationsViewModel()
    @EnvironmentObject var socket: SocketClient
    @State private var showNewChat = false
    @State private var filter = ""
    @State private var path = NavigationPath()

    private var filtered: [Conversation] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [Conversation]
        if q.isEmpty {
            base = vm.conversations
        } else {
            base = vm.conversations.filter { c in
                c.displayTitle.lowercased().contains(q)
                    || (c.previewText ?? "").lowercased().contains(q)
                    || c.participantsOrEmpty.contains(where: { $0.login.lowercased().contains(q) })
            }
        }
        return base.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return (a.last_message_at ?? "") > (b.last_message_at ?? "")
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if vm.isLoading && vm.conversations.isEmpty {
                    SkeletonList(count: 10, avatarSize: 50)
                } else if vm.conversations.isEmpty {
                    ContentUnavailableCompat(
                        title: "No conversations yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: "Tap the pencil icon to start one."
                    )
                } else {
                    List(filtered) { convo in
                        NavigationLink(value: convo) {
                            ConversationRow(conversation: convo)
                        }
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task { await vm.togglePin(convo) }
                            } label: {
                                Label(convo.isPinned ? "Unpin" : "Pin", systemImage: convo.isPinned ? "pin.slash.fill" : "pin.fill")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await vm.delete(convo) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await vm.load() }
                }
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .navigationDestination(for: Conversation.self) { convo in
                ChatDetailView(conversation: convo)
            }
            .sheet(isPresented: $showNewChat) {
                NewChatView { convo in
                    Task {
                        await vm.load()
                        path.append(convo)
                    }
                }
            }
            .task {
                if vm.conversations.isEmpty { await vm.load() }
                socket.onConversationUpdated = { Task { await vm.load() } }
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: conversation.displayAvatarURL, size: 50)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if conversation.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.accentColor, in: .capsule)
                            .foregroundStyle(.white)
                    }
                }
                Text(conversation.previewText ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AvatarView: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill()
            default:
                Color.accentColor.opacity(0.2)
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct ContentUnavailableCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        if #available(iOS 17, *) {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
        } else {
            VStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 48)).foregroundStyle(.secondary)
                Text(title).font(.title3.bold())
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
