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
    @StateObject private var router = AppRouter.shared
    @EnvironmentObject var socket: SocketClient
    @State private var showNewChat = false
    @State private var filter = ""
    @State private var path = NavigationPath()
    @State private var confirmDelete: Conversation?

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
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
                        .contextMenu {
                            Button {
                                Task { await vm.togglePin(convo) }
                            } label: {
                                Label(convo.isPinned ? "Unpin" : "Pin", systemImage: convo.isPinned ? "pin.slash" : "pin")
                            }
                            Button {
                                Task {
                                    do {
                                        if convo.is_muted == true {
                                            try await APIClient.shared.unmuteConversation(id: convo.id)
                                            ToastCenter.shared.show(.info, "Unmuted")
                                        } else {
                                            try await APIClient.shared.muteConversation(id: convo.id)
                                            ToastCenter.shared.show(.success, "Muted")
                                        }
                                        await vm.load()
                                    } catch {
                                        ToastCenter.shared.show(.error, "Mute failed", error.localizedDescription)
                                    }
                                }
                            } label: {
                                Label(convo.is_muted == true ? "Unmute" : "Mute", systemImage: convo.is_muted == true ? "bell" : "bell.slash")
                            }
                            Button(role: .destructive) {
                                confirmDelete = convo
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                        .tint(.primary)
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.hidden)
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
            .alert("Delete conversation?", isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ), presenting: confirmDelete) { convo in
                Button("Delete", role: .destructive) {
                    Task { await vm.delete(convo) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Messages will be removed from your list.")
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
            .onAppear {
                // Re-bind hook in case chat detail cleared it, and refresh
                // so the list reflects anything sent from inside a chat.
                socket.onConversationUpdated = { Task { await vm.load() } }
                Task { await vm.load() }
            }
            .onChange(of: router.pendingConversationId) { id in
                guard let id else { return }
                Task {
                    await vm.load()
                    if let convo = vm.conversations.first(where: { $0.id == id }) {
                        path.append(convo)
                    }
                    router.pendingConversationId = nil
                }
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            if conversation.isGroup && !conversation.participantsOrEmpty.isEmpty {
                GroupAvatarCluster(
                    participants: Array(conversation.participantsOrEmpty.prefix(3)),
                    size: 50
                )
            } else {
                AvatarView(url: conversation.displayAvatarURL, size: 50)
            }
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

/// Cluster of up to 3 participant avatars arranged inside a fixed square so
/// group rows feel distinct from single-user rows.
struct GroupAvatarCluster: View {
    let participants: [ConversationParticipant]
    let size: CGFloat

    var body: some View {
        ZStack {
            Color.clear.frame(width: size, height: size)
            if participants.count >= 3 {
                AvatarView(url: participants[2].avatar_url, size: size * 0.55)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                    .offset(x: -size * 0.18, y: -size * 0.18)
                AvatarView(url: participants[1].avatar_url, size: size * 0.45)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                    .offset(x: size * 0.22, y: -size * 0.08)
                AvatarView(url: participants[0].avatar_url, size: size * 0.40)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                    .offset(x: -size * 0.02, y: size * 0.22)
            } else if participants.count == 2 {
                AvatarView(url: participants[1].avatar_url, size: size * 0.6)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                    .offset(x: -size * 0.16, y: -size * 0.12)
                AvatarView(url: participants[0].avatar_url, size: size * 0.55)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                    .offset(x: size * 0.18, y: size * 0.14)
            } else if let first = participants.first {
                AvatarView(url: first.avatar_url, size: size * 0.8)
            }
        }
        .frame(width: size, height: size)
    }
}

struct AvatarView: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        CachedAvatarImage(url: url.flatMap(URL.init(string:)))
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

private struct CachedAvatarImage: View {
    let url: URL?
    @State private var image: UIImage?

    init(url: URL?) {
        self.url = url
        if let url {
            _image = State(initialValue: ImageCache.shared.image(for: url))
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.accentColor.opacity(0.2)
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.white))
            }
        }
        .task(id: url) {
            guard image == nil, let url else { return }
            let loaded = await ImageCache.shared.load(url)
            await MainActor.run { self.image = loaded }
        }
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
