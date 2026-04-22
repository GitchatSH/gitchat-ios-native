import SwiftUI

@MainActor
final class ConversationsViewModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var isLoading = false
    @Published var isSyncing = false
    @Published var error: String?
    /// Conversation ids that the user has tapped/opened locally —
    /// rendered as zero unread immediately, before the server-side
    /// markRead call comes back.
    @Published var locallyRead: Set<String> = []
    @Published var locallyMuted: Set<String> = []
    @Published var locallyUnmuted: Set<String> = []

    func markLocallyRead(_ id: String) {
        locallyRead.insert(id)
    }

    func isLocallyMuted(_ convo: Conversation) -> Bool {
        if locallyMuted.contains(convo.id) { return true }
        if locallyUnmuted.contains(convo.id) { return false }
        return convo.is_muted == true
    }

    func toggleMute(_ convo: Conversation) async {
        let wasMuted = isLocallyMuted(convo)
        if wasMuted {
            locallyMuted.remove(convo.id)
            locallyUnmuted.insert(convo.id)
        } else {
            locallyUnmuted.remove(convo.id)
            locallyMuted.insert(convo.id)
        }
        do {
            if wasMuted {
                try await APIClient.shared.unmuteConversation(id: convo.id)
                ToastCenter.shared.show(.info, "Unmuted")
            } else {
                try await APIClient.shared.muteConversation(id: convo.id)
                ToastCenter.shared.show(.success, "Muted")
            }
            await load()
        } catch {
            if wasMuted {
                locallyUnmuted.remove(convo.id)
                locallyMuted.insert(convo.id)
            } else {
                locallyMuted.remove(convo.id)
                locallyUnmuted.insert(convo.id)
            }
            ToastCenter.shared.show(.error, "Mute failed", error.localizedDescription)
        }
    }

    init() {
        if let cached = ConversationsCache.shared.get() {
            self.conversations = cached
        }
    }

    /// Keep one conversation per case-insensitive `repo_full_name`
    /// (or `group_name` fallback). Picks the entry with the most
    /// recent `last_message_at` so users see the active row.
    static func dedupeChannels(_ list: [Conversation]) -> [Conversation] {
        var byKey: [String: Conversation] = [:]
        var ordered: [Conversation] = []
        for convo in list {
            let key: String?
            if convo.isGroup, let repo = convo.repo_full_name, !repo.isEmpty {
                key = "repo:\(repo.lowercased())"
            } else if convo.isGroup, let name = convo.group_name, !name.isEmpty {
                key = "group:\(name.lowercased())"
            } else {
                key = nil
            }
            guard let key else {
                ordered.append(convo)
                continue
            }
            if let existing = byKey[key] {
                if (convo.last_message_at ?? "") > (existing.last_message_at ?? "") {
                    byKey[key] = convo
                    if let idx = ordered.firstIndex(where: { $0.id == existing.id }) {
                        ordered[idx] = convo
                    }
                }
            } else {
                byKey[key] = convo
                ordered.append(convo)
            }
        }
        return ordered
    }

    func load() async {
        if conversations.isEmpty { isLoading = true }
        isSyncing = true
        let started = Date()
        defer { isLoading = false }
        do {
            let resp = try await APIClient.shared.listConversations()
            // Dedupe group/channel conversations whose repo_full_name
            // collides case-insensitively. Backend stores both
            // `open-acp/openacp` and `Open-ACP/OpenACP` as separate
            // rows; on the client we keep the one with the most
            // recent activity so the user sees a single chat.
            let deduped = Self.dedupeChannels(resp.conversations)
            self.conversations = deduped
            ConversationsCache.shared.store(deduped)
            for convo in deduped {
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
    @State private var selectedConvo: Conversation? = nil
    @State private var tappedConvoId: String?

    private var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    private func openConversation(_ convo: Conversation) {
        withAnimation(.none) { tappedConvoId = convo.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            tappedConvoId = nil
        }
        vm.markLocallyRead(convo.id)
        #if targetEnvironment(macCatalyst)
        selectedConvo = convo
        #else
        path.append(convo)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    @ViewBuilder
    private var macSidebar: some View {
        if #available(iOS 17.0, *) {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                .toolbar(removing: .sidebarToggle)
        } else {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        }
    }
    #endif

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
        #if targetEnvironment(macCatalyst)
        NavigationSplitView(columnVisibility: .constant(.all)) {
            macSidebar
        } detail: {
            if let convo = selectedConvo {
                NavigationStack {
                    ChatDetailView(conversation: convo)
                }
                // Force a fresh ChatDetailView (new @StateObject) when
                // a different conversation is selected — without this
                // the existing view re-uses the old ChatViewModel.
                .id(convo.id)
            } else {
                ContentUnavailableCompat(
                    title: "Select a conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: "Pick a chat from the sidebar to start reading."
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(
            // Hidden button that installs a window-level Esc shortcut.
            // SwiftUI bridges keyboardShortcut to a UIKeyCommand on
            // Catalyst, which fires regardless of focus.
            Button("") { selectedConvo = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        )
        #else
        NavigationStack(path: $path) {
            sidebar
                .navigationDestination(for: Conversation.self) { convo in
                    ChatDetailView(conversation: convo)
                }
        }
        #endif
    }

    private var sidebar: some View {
        Group {
                if vm.isLoading && vm.conversations.isEmpty {
                    SkeletonList(count: 10, avatarSize: 50)
                } else if vm.conversations.isEmpty {
                    ContentUnavailableCompat(
                        title: "No conversations yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: "Tap the pencil icon to start one."
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableCompat(
                        title: "No results",
                        systemImage: "magnifyingglass",
                        description: "Try a different search."
                    )
                } else {
                    List(filtered) { convo in
                        Button {
                            openConversation(convo)
                        } label: {
                            ConversationRow(
                                conversation: convo,
                                isLocallyRead: vm.locallyRead.contains(convo.id),
                                isMuted: vm.isLocallyMuted(convo)
                            )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .macHover()
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .scaleEffect(tappedConvoId == convo.id ? 0.97 : 1)
                        .opacity(tappedConvoId == convo.id ? 0.7 : 1)
                        .listRowBackground(
                            convo.isPinned
                                ? Color("AccentColor").opacity(0.08)
                                : Color.clear
                        )
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
                            .tint(.red)
                        }
                        .contextMenu {
                            Button {
                                Task { await vm.togglePin(convo) }
                            } label: {
                                Label(convo.isPinned ? "Unpin" : "Pin", systemImage: convo.isPinned ? "pin.slash" : "pin")
                            }
                            Button {
                                Task { await vm.toggleMute(convo) }
                            } label: {
                                Label(vm.isLocallyMuted(convo) ? "Unmute" : "Mute", systemImage: vm.isLocallyMuted(convo) ? "bell" : "bell.slash")
                            }
                            Button(role: .destructive) {
                                confirmDelete = convo
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
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
            .sheet(isPresented: $showNewChat) {
                NewChatView { convo in
                    Task {
                        await vm.load()
                        openConversation(convo)
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
                Task {
                    await vm.load()
                    // Cold start from a push tap: the OneSignal click
                    // handler may have set pendingConversationId before
                    // this view attached its .onChange, so consume it
                    // here after the initial load.
                    if let pendingId = router.pendingConversationId {
                        if let convo = vm.conversations.first(where: { $0.id == pendingId }) {
                            openConversation(convo)
                        }
                        router.pendingConversationId = nil
                    }
                }
            }
            .onChange(of: router.pendingConversationId) { id in
                guard let id else { return }
                if let convo = vm.conversations.first(where: { $0.id == id }) {
                    openConversation(convo)
                    router.pendingConversationId = nil
                } else {
                    Task {
                        await vm.load()
                        if let convo = vm.conversations.first(where: { $0.id == id }) {
                            openConversation(convo)
                        }
                        router.pendingConversationId = nil
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
                .foregroundStyle(Color("AccentColor"))
                .rotationEffect(.degrees(seconds.truncatingRemainder(dividingBy: 1) * 360))
        }
        .accessibilityLabel("Syncing")
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    var isLocallyRead: Bool = false
    var isMuted: Bool = false

    private var displayedUnread: Int {
        isLocallyRead ? 0 : conversation.unreadCount
    }

    /// Pull the most recent attachment URL out of the message cache so
    /// "📷 Photo" preview rows can show an actual thumbnail instead of
    /// the camera emoji.
    private var lastPhotoURL: URL? {
        guard let messages = MessageCache.shared.get(conversation.id)?.messages,
              let last = messages.last else { return nil }
        if let urlString = last.attachments?.first?.url, let url = URL(string: urlString) {
            return url
        }
        if let urlString = last.attachment_url, let url = URL(string: urlString) {
            return url
        }
        return nil
    }

    private var lastSenderLogin: String? {
        guard conversation.isGroup else { return nil }
        if let cached = MessageCache.shared.get(conversation.id)?.messages,
           let last = cached.last, last.type == nil || last.type == "user" {
            return last.sender
        }
        return conversation.last_message?.sender
    }

    private var previewWithoutPhotoEmoji: String {
        let text = conversation.previewText ?? ""
        guard lastPhotoURL != nil else { return text }
        // Drop the leading "📷 Photo" / "📎 …" / etc when we have a real
        // thumbnail next to it.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let prefixes = ["📷 Photo", "🎥 Video", "📎 Attachment", "📎 Shared a post", "📎 Shared an event"]
        for p in prefixes where trimmed == p {
            return ""
        }
        return text
    }

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
                            .instantTooltip("Pinned")
                    }
                    if isMuted {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
                            .instantTooltip("Muted")
                    }
                }
                if let sender = lastSenderLogin {
                    Text(sender)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(alignment: .top, spacing: 6) {
                    if let thumbURL = lastPhotoURL {
                        CachedAsyncImage(
                            url: thumbURL,
                            contentMode: .fill,
                            maxPixelSize: 80
                        )
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Text(previewWithoutPhotoEmoji)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text(RelativeTime.chatListStamp(conversation.last_message_at))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .instantTooltip(MessageBubble.fullTimestamp(conversation.last_message_at))
                if displayedUnread > 0 {
                    let isMutedBadge = isMuted
                    Text("\(displayedUnread)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(isMutedBadge ? Color(.systemGray3) : Color("AccentColor"), in: .capsule)
                        .foregroundStyle(isMutedBadge ? Color(.label) : .white)
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

    /// GitHub avatars (github.com/<login>.png) are served from the same
    /// URL but the underlying image changes when the user updates their
    /// avatar. To keep avatars reasonably fresh we append a daily
    /// cache-buster query param so each day produces a new cache key.
    private static func dailyBustedURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let host = url.host?.lowercased() ?? ""
        guard host == "github.com" || host.hasSuffix(".githubusercontent.com") else {
            return url
        }
        let day = Calendar(identifier: .gregorian).ordinality(of: .day, in: .era, for: Date()) ?? 0
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "d", value: "\(day)"))
        comps?.queryItems = items
        return comps?.url ?? url
    }

    init(url: URL?) {
        let busted = Self.dailyBustedURL(url)
        self.url = busted
        if let busted {
            _image = State(initialValue: ImageCache.shared.image(for: busted, maxPixelSize: maxPixelSize))
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color("AccentColor").opacity(0.2)
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
