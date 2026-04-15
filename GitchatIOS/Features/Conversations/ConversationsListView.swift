import SwiftUI

@MainActor
final class ConversationsViewModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var isLoading = false
    @Published var isSyncing = false
    @Published var error: String?

    init() {
        if let cached = ConversationsCache.shared.get() {
            self.conversations = cached
        }
    }

    func load() async {
        if conversations.isEmpty { isLoading = true }
        isSyncing = true
        let started = Date()
        defer { isLoading = false }
        do {
            let resp = try await APIClient.shared.listConversations()
            self.conversations = resp.conversations
            ConversationsCache.shared.store(resp.conversations)
            for convo in resp.conversations {
                MessageCache.shared.prefetch(conversationId: convo.id)
            }
        } catch {
            self.error = error.localizedDescription
        }
        // Keep the syncing indicator on screen for at least 2s so the
        // user has time to notice the sync happened.
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 2 {
            try? await Task.sleep(nanoseconds: UInt64((2 - elapsed) * 1_000_000_000))
        }
        isSyncing = false
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
            // Backend caps pinned conversations at 3 (LIMIT_REACHED →
            // "Maximum 3 pinned conversations"). Show the exact copy.
            let raw = error.localizedDescription.lowercased()
            if raw.contains("maximum") || raw.contains("limit") || raw.contains("pinned") {
                ToastCenter.shared.show(.warning, "Maximum 3 pinned conversations")
            } else {
                self.error = error.localizedDescription
                ToastCenter.shared.show(.error, "Couldn't pin", error.localizedDescription)
            }
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
    @Environment(\.scenePhase) private var scenePhase
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
                        ZStack {
                            NavigationLink(value: convo) { EmptyView() }
                                .opacity(0)
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
                    .animation(.spring(response: 0.45, dampingFraction: 0.82), value: vm.conversations.map(\.id))
                }
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if vm.isSyncing {
                        SyncingIndicator()
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.isSyncing)
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
                await vm.load()
                socket.onConversationUpdated = { Task { await vm.load() } }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await vm.load() } }
            }
            .onAppear {
                // Re-bind hook in case chat detail cleared it, and refresh
                // so the list reflects anything sent from inside a chat.
                socket.onConversationUpdated = { Task { await vm.load() } }
                Task { await vm.load() }
            }
            .onChange(of: router.pendingConversationId) { id in
                guard let id else { return }
                // Push immediately using whatever we already have —
                // the cached conversation list or a minimal stub — so
                // the user lands in the chat with zero delay. The
                // chat view model will revalidate from the network on
                // its own.
                if let convo = vm.conversations.first(where: { $0.id == id }) {
                    path.append(convo)
                    router.pendingConversationId = nil
                } else {
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
}

struct SyncingIndicator: View {
    var body: some View {
        // Wall-clock driven rotation so the glyph is always spinning
        // whenever this view is on screen — independent of any
        // .onAppear firing or @State being re-used across reappearances.
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .rotationEffect(.degrees(seconds.truncatingRemainder(dividingBy: 1) * 360))
        }
        .accessibilityLabel("Syncing")
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
                AvatarView(
                    url: conversation.displayAvatarURL,
                    size: 50,
                    login: conversation.other_user?.login
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(conversation.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if conversation.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(conversation.previewText ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text(RelativeTime.chatListStamp(conversation.last_message_at))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if conversation.unreadCount > 0 {
                    Text("\(conversation.unreadCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.accentColor, in: .capsule)
                        .foregroundStyle(.white)
                } else {
                    Color.clear.frame(width: 1, height: 18)
                }
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
    var login: String? = nil
    @ObservedObject private var presence = PresenceStore.shared

    var body: some View {
        CachedAvatarImage(url: url.flatMap(URL.init(string:)))
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                if let login, presence.isOnline(login) {
                    let dot = max(8, size * 0.28)
                    Circle()
                        .fill(Color.green)
                        .frame(width: dot, height: dot)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: max(1, dot * 0.18)))
                }
            }
            .onAppear {
                if let login { presence.ensure([login]) }
            }
    }
}

private struct CachedAvatarImage: View {
    let url: URL?
    private let maxPixelSize: CGFloat = 96
    @State private var image: UIImage?

    init(url: URL?) {
        self.url = url
        if let url {
            _image = State(initialValue: ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize))
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
            let loaded = await ImageCache.shared.load(url, maxPixelSize: maxPixelSize)
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
