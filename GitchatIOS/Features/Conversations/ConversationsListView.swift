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
    @Published var isLoadingMore = false
    private var nextCursor: String?
    private var loadTask: Task<Void, Never>?

    func markLocallyRead(_ id: String) {
        locallyRead.insert(id)
    }

    func toggleRead(_ convo: Conversation) {
        if locallyRead.contains(convo.id) {
            locallyRead.remove(convo.id)
        } else {
            locallyRead.insert(convo.id)
        }
    }

    /// Sum of unread counts across all conversations, treating ones the
    /// user has tapped locally as already read so the badge updates the
    /// instant they open a chat.
    var totalUnreadCount: Int {
        conversations.reduce(0) { acc, c in
            acc + (locallyRead.contains(c.id) ? 0 : c.unreadCount)
        }
    }

    /// Patch a conversation row's preview + timestamp in-place so the
    /// list reflects a just-arrived message without waiting for a full
    /// `listConversations()` refetch. Used by the socket `message:sent`
    /// listener — BE doesn't always emit `conversation:updated` alongside.
    func applyIncomingMessage(_ msg: Message) {
        guard let cid = msg.conversation_id,
              let idx = conversations.firstIndex(where: { $0.id == cid }) else { return }
        let c = conversations[idx]
        let preview = msg.content.isEmpty ? c.last_message_preview : msg.content
        conversations[idx] = c.withLastMessage(msg, preview: preview)
        ConversationsCache.shared.store(conversations)
    }

    /// Patch a row's group name + avatar in place after the user saves
    /// group settings from inside the chat. BE emits
    /// `conversation:updated` too, but not always reliably — without
    /// this optimistic patch the list stays on the old avatar until a
    /// cold reload.
    func applyLocalMetadata(id: String, name: String?, avatarUrl: String?) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        let c = conversations[idx]
        conversations[idx] = Conversation(
            id: c.id,
            type: c.type,
            is_group: c.is_group,
            group_name: name ?? c.group_name,
            group_avatar_url: avatarUrl ?? c.group_avatar_url,
            repo_full_name: c.repo_full_name,
            participants: c.participants,
            other_user: c.other_user,
            last_message: c.last_message,
            last_message_preview: c.last_message_preview,
            last_message_text: c.last_message_text,
            last_message_at: c.last_message_at,
            unread_count: c.unread_count,
            pinned: c.pinned,
            pinned_at: c.pinned_at,
            is_request: c.is_request,
            updated_at: c.updated_at,
            is_muted: c.is_muted
        )
        ConversationsCache.shared.store(conversations)
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
            MutedConversationsStore.remove(convo.id)
        } else {
            locallyUnmuted.remove(convo.id)
            locallyMuted.insert(convo.id)
            MutedConversationsStore.insert(convo.id)
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
                MutedConversationsStore.insert(convo.id)
            } else {
                locallyMuted.remove(convo.id)
                locallyUnmuted.insert(convo.id)
                MutedConversationsStore.remove(convo.id)
            }
            ToastCenter.shared.show(.error, "Mute failed", error.localizedDescription)
        }
    }

    /// Refresh the shared (app-group) muted-id set from the latest
    /// server-returned conversations. Merged with any optimistic
    /// flips that haven't completed yet.
    private func syncMutedStore() {
        var ids = Set(conversations.filter { $0.is_muted == true }.map(\.id))
        ids.formUnion(locallyMuted)
        ids.subtract(locallyUnmuted)
        MutedConversationsStore.replace(with: ids)
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

    func load(reset: Bool = true) async {
        loadTask?.cancel()
        let task = Task { @MainActor in
            if reset {
                if conversations.isEmpty { isLoading = true }
                isSyncing = true
            }
            let started = Date()
            defer {
                if reset { isLoading = false }
            }
            do {
                let cursor = reset ? nil : nextCursor
                let resp = try await APIClient.shared.listConversations(cursor: cursor)
                guard !Task.isCancelled else { return }

                if reset {
                    let deduped = Self.dedupeChannels(resp.conversations)
                    self.conversations = deduped
                    self.locallyRead.removeAll()
                    // Keep locallyMuted/locallyUnmuted — syncMutedStore() reconciles them
                } else {
                    let existingIds = Set(conversations.map(\.id))
                    let newConvos = resp.conversations.filter { !existingIds.contains($0.id) }
                    let merged = conversations + newConvos
                    self.conversations = Self.dedupeChannels(merged)
                }

                self.nextCursor = resp.nextCursor
                ConversationsCache.shared.store(conversations)
                syncMutedStore()
                for convo in resp.conversations {
                    MessageCache.shared.prefetch(conversationId: convo.id)
                }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
            if reset {
                let elapsed = Date().timeIntervalSince(started)
                if elapsed < 2 {
                    try? await Task.sleep(nanoseconds: UInt64((2 - elapsed) * 1_000_000_000))
                }
                isSyncing = false
            }
            isLoadingMore = false
        }
        loadTask = task
        await task.value
    }

    func loadMoreIfNeeded(current: Conversation) {
        guard !isLoadingMore, nextCursor != nil else { return }
        let thresholdIndex = conversations.index(conversations.endIndex, offsetBy: -5, limitedBy: conversations.startIndex) ?? conversations.startIndex
        if let currentIndex = conversations.firstIndex(where: { $0.id == current.id }),
           currentIndex >= thresholdIndex {
            isLoadingMore = true
            Task { await load(reset: false) }
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
    @State private var tappedConvoId: String?
    /// Row currently in the 0.32s "press-in squeeze" before the peek
    /// fires — Telegram's pre-activation feedback (`ContextControllerSourceNode.swift`).
    @State private var squeezedConvoId: String?
    /// Token guards the 0.12s delay → 0.20s ramp sequence: if the
    /// user lifts before the delay completes we want to abort the
    /// scheduled state update.
    @State private var pressToken = UUID()

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
        router.selectedConversation = convo
        #else
        path.append(convo)
        #endif
    }

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
        coreBody
    }

    /// Telegram's `max(0.7, (w-15)/w)`. For typical full-width row
    /// (~screen width), gives ~0.96 — a barely-perceptible squeeze
    /// that reads as "the row is being grabbed". Smaller controls
    /// would squeeze toward 0.7.
    private func rowSqueezeFactor(for convo: Conversation) -> CGFloat {
        let w = UIScreen.main.bounds.width
        return max(0.7, (w - 15) / w)
    }

    private func presentPeek(for convo: Conversation) {
        // Window-level overlay so the blur covers the tab bar and
        // nav bar — Telegram does the same with their Display
        // framework's overlay window stack.
        PeekHostWindow.shared.present {
            ConversationPeekOverlay(
                conversation: convo,
                myLogin: AuthStore.shared.login,
                actions: peekActions(for: convo),
                onCommit: { openConversation(convo) },
                onDismiss: { PeekHostWindow.shared.dismiss() }
            )
        }
    }

    private func peekActions(for convo: Conversation) -> [PeekMenuAction] {
        let muted = vm.isLocallyMuted(convo)
        let pinned = convo.isPinned
        return [
            PeekMenuAction(
                title: pinned ? "Unpin" : "Pin",
                systemImage: pinned ? "pin.slash" : "pin"
            ) { Task { await vm.togglePin(convo) } },
            PeekMenuAction(
                title: muted ? "Unmute" : "Mute",
                systemImage: muted ? "bell" : "bell.slash"
            ) { Task { await vm.toggleMute(convo) } },
            PeekMenuAction(
                title: "Delete",
                systemImage: "trash",
                isDestructive: true
            ) { confirmDelete = convo },
        ]
    }

    @ViewBuilder
    private var coreBody: some View {
        #if targetEnvironment(macCatalyst)
        sidebar
        #else
        NavigationStack(path: $path) {
            sidebar
                .navigationDestination(for: Conversation.self) { convo in
                    ChatDetailView(conversation: convo)
                }
        }
        #endif
    }

    /// On Catalyst, a row is "active" when its conversation is the
    /// one currently shown in the sticky detail panel. Highlights the
    /// row so the user can see which chat is loaded on the right.
    private func isActiveRow(_ convo: Conversation) -> Bool {
        #if targetEnvironment(macCatalyst)
        return router.selectedConversation?.id == convo.id
        #else
        return false
        #endif
    }

    @ViewBuilder
    private func rowBackground(for convo: Conversation) -> some View {
        let fill: Color? = {
            if isActiveRow(convo) { return Color("AccentColor") }
            if convo.isPinned { return Color("AccentColor").opacity(0.08) }
            return nil
        }()

        if let fill {
            #if targetEnvironment(macCatalyst)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fill)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            #else
            fill
            #endif
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func conversationListRow(_ convo: Conversation) -> some View {
        ConversationRow(
            conversation: convo,
            isLocallyRead: vm.locallyRead.contains(convo.id),
            isMuted: vm.isLocallyMuted(convo),
            isActive: isActiveRow(convo)
        )
        .contentShape(Rectangle())
        // Telegram-style press: 0.12s delay, then 0.20s squeeze
        // ramp, then activate at 0.32s. `onPressingChanged` fires
        // immediately on touch / release; we use a token to guard
        // the deferred squeeze against early lifts.
        .scaleEffect(squeezedConvoId == convo.id ? rowSqueezeFactor(for: convo) : 1)
        .animation(.easeOut(duration: 0.20), value: squeezedConvoId == convo.id)
        .onTapGesture { openConversation(convo) }
        .onLongPressGesture(minimumDuration: 0.32) {
            squeezedConvoId = nil
            pressToken = UUID()
            Haptics.impact(.medium)
            presentPeek(for: convo)
        } onPressingChanged: { isPressing in
            if isPressing {
                let token = UUID()
                pressToken = token
                let id = convo.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard pressToken == token else { return }
                    squeezedConvoId = id
                }
            } else {
                pressToken = UUID()
                squeezedConvoId = nil
            }
        }
        .macHover()
        .listRowSeparator(.hidden)
        #if targetEnvironment(macCatalyst)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        #else
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        #endif
        .scaleEffect(tappedConvoId == convo.id ? 0.97 : 1)
        .opacity(tappedConvoId == convo.id ? 0.7 : 1)
        .listRowBackground(rowBackground(for: convo))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                vm.toggleRead(convo)
            } label: {
                Label(
                    vm.locallyRead.contains(convo.id) || convo.unreadCount == 0 ? "Unread" : "Read",
                    systemImage: vm.locallyRead.contains(convo.id) || convo.unreadCount == 0 ? "envelope.badge.fill" : "envelope.open.fill"
                )
            }
            .tint(Color(.systemGreen))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmDelete = convo
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            Button {
                Task { await vm.toggleMute(convo) }
            } label: {
                let muted = vm.isLocallyMuted(convo)
                Label(muted ? "Unmute" : "Mute", systemImage: muted ? "bell.fill" : "bell.slash.fill")
            }
            .tint(.orange)
            Button {
                Task { await vm.togglePin(convo) }
            } label: {
                Label(convo.isPinned ? "Unpin" : "Pin", systemImage: convo.isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(Color(.systemBlue))
        }
        .onAppear {
            vm.loadMoreIfNeeded(current: convo)
        }
    }

    private var sidebar: some View {
        Group {
                if vm.isLoading && vm.conversations.isEmpty {
                    SkeletonList(count: 10, avatarSize: 56)
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
                    List {
                        ForEach(filtered) { convo in
                            conversationListRow(convo)
                                .hideMacScrollIndicators()
                        }
                        if vm.isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .macRowListContainer()
                    .scrollIndicators(.hidden, axes: .vertical)
                    .refreshable { await vm.load() }
                    .animation(vm.isLoadingMore ? .none : .spring(response: 0.45, dampingFraction: 0.82), value: vm.conversations.map(\.id))
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
                DraftStore.shared.loadAll(for: vm.conversations.map(\.id))
                socket.onConversationUpdated = { Task { await vm.load() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .gitchatMessageSent)) { note in
                guard let msg = note.object as? Message else { return }
                vm.applyIncomingMessage(msg)
            }
            .onReceive(NotificationCenter.default.publisher(for: .gitchatConversationMetadataChanged)) { note in
                guard let info = note.userInfo,
                      let id = info["id"] as? String else { return }
                let name = info["name"] as? String
                let avatarUrl = info["avatarUrl"] as? String
                vm.applyLocalMetadata(id: id, name: name, avatarUrl: avatarUrl)
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
    /// On Catalyst, `true` when this row is the conversation showing
    /// in the sticky detail panel. Flips text/icon colors to white
    /// for contrast against the accent-color background.
    var isActive: Bool = false
    @ObservedObject private var draftStore = DraftStore.shared

    private var primaryTextColor: Color { isActive ? .white : .primary }
    private var secondaryTextColor: Color { isActive ? .white.opacity(0.85) : .secondary }

    /// Avatar diameter — 44pt on Catalyst (Apple list standard),
    /// 50pt on iOS for the Telegram-feeling chat-list look.
    private var avatarSize: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 44
        #else
        return 56
        #endif
    }

    private var metaFont: Font {
        #if targetEnvironment(macCatalyst)
        return .footnote
        #else
        return .footnote
        #endif
    }

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

    @ViewBuilder
    private var previewContent: some View {
        if let msg = conversation.last_message, (msg.type ?? "user") != "user" {
            // System message — italic
            Text(previewWithoutPhotoEmoji)
                .font(.subheadline.italic())
                .foregroundStyle(Color(.systemGray2))
                .lineLimit(2)
        } else if conversation.isGroup && isOutgoing && conversation.last_message != nil {
            // Group outgoing — "You:" prefix
            (Text("You: ").foregroundColor(Color("AccentColor")).font(.subheadline)
            + Text(previewWithoutPhotoEmoji).foregroundColor(secondaryTextColor).font(.subheadline))
            .lineLimit(2)
        } else {
            Text(previewWithoutPhotoEmoji)
                .font(.subheadline)
                .foregroundStyle(secondaryTextColor)
                .lineLimit(2)
        }
    }

    private enum CheckmarkState {
        case none, sending, sent, read, failed
    }

    private var isOutgoing: Bool {
        guard let login = AuthStore.shared.login,
              let sender = conversation.last_message?.sender else { return false }
        return sender == login
    }

    private var hasMention: Bool {
        guard displayedUnread > 0,
              conversation.isGroup,
              let content = conversation.last_message?.content,
              !content.isEmpty,
              let login = AuthStore.shared.login else { return false }
        let pattern = "(?<![\\w])@\(NSRegularExpression.escapedPattern(for: login))(?![\\w])"
        return content.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private var checkmarkState: CheckmarkState {
        guard isOutgoing, let msg = conversation.last_message else { return .none }
        if msg.unsent_at != nil { return .failed }
        if msg.id.hasPrefix("local-") { return .sending }
        guard let createdAt = msg.created_at else { return .sent }
        if let cache = MessageCache.shared.get(conversation.id) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFallback = ISO8601DateFormatter()
            isoFallback.formatOptions = [.withInternetDateTime]
            func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? isoFallback.date(from: s) }
            if conversation.isGroup {
                if let cursors = cache.readCursors, let msgDate = parseDate(createdAt) {
                    let otherRead = cursors.contains { login, readAt in
                        guard login != AuthStore.shared.login,
                              let cursorDate = parseDate(readAt) else { return false }
                        return cursorDate >= msgDate
                    }
                    if otherRead { return .read }
                }
            } else if let otherReadAt = cache.otherReadAt {
                if let readDate = parseDate(otherReadAt),
                   let msgDate = parseDate(createdAt),
                   readDate >= msgDate {
                    return .read
                }
            }
        }
        return .sent
    }

    var body: some View {
        HStack(spacing: 12) {
            if conversation.isGroup {
                GroupAvatarView(
                    name: conversation.group_name ?? conversation.displayTitle,
                    avatarURL: conversation.group_avatar_url,
                    groupId: conversation.id,
                    size: avatarSize
                )
            } else {
                AvatarView(
                    url: conversation.displayAvatarURL,
                    size: avatarSize,
                    login: conversation.other_user?.login
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.displayTitle)
                    .font(displayedUnread > 0 ? .headline : .body)
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)
                if let sender = lastSenderLogin, !isOutgoing {
                    HStack(spacing: 4) {
                        if let avatarURL = conversation.last_message?.sender_avatar,
                           let url = URL(string: avatarURL) {
                            CachedAsyncImage(
                                url: url,
                                contentMode: .fill,
                                maxPixelSize: 60
                            )
                            .frame(width: 20, height: 20)
                            .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color(.systemGray4))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    Text(String(sender.prefix(1)).uppercased())
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                        }
                        Text(sender)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    if let draft = draftStore.draft(for: conversation.id) {
                        (Text("Draft: ").foregroundColor(Color(.systemRed)).font(.subheadline)
                        + Text(draft).foregroundColor(secondaryTextColor).font(.subheadline))
                        .lineLimit(2)
                    } else {
                        if let thumbURL = lastPhotoURL {
                            CachedAsyncImage(
                                url: thumbURL,
                                contentMode: .fill,
                                maxPixelSize: 80
                            )
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        previewContent
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    switch checkmarkState {
                    case .sending:
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(.systemGray))
                    case .sent:
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(.systemGray))
                    case .read:
                        ZStack {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .medium))
                                .offset(x: 4)
                        }
                        .foregroundStyle(Color("AccentColor"))
                    case .failed:
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(.systemRed))
                    case .none:
                        EmptyView()
                    }
                    Text(RelativeTime.chatListStamp(conversation.last_message_at))
                        .font(metaFont)
                        .foregroundStyle(displayedUnread > 0 && !isActive ? Color("AccentColor") : secondaryTextColor)
                        .instantTooltip(ChatMessageText.fullTimestamp(conversation.last_message_at))
                }
                HStack(spacing: 4) {
                    if displayedUnread > 0 {
                        if hasMention {
                            Text("@")
                                .font(.caption.bold())
                                .frame(width: 20, height: 20)
                                .background(Color("AccentColor"), in: Circle())
                                .foregroundStyle(.white)
                        }
                        Text("\(displayedUnread)")
                            .font(.footnote.bold())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .frame(minWidth: 24, minHeight: 24)
                            .background(
                                isActive
                                    ? Color.white
                                    : (isMuted ? Color(.systemGray) : Color("AccentColor")),
                                in: .capsule
                            )
                            .foregroundStyle(
                                isActive
                                    ? Color("AccentColor")
                                    : .white
                            )
                        if isMuted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(secondaryTextColor)
                        }
                    } else if conversation.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryTextColor)
                        if isMuted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(secondaryTextColor)
                        }
                    } else {
                        Color.clear.frame(width: 1, height: 24)
                    }
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .padding(.horizontal, macRowHorizontalPadding)
        .padding(.vertical, macRowVerticalPadding)
        #else
        .padding(.vertical, 12)
        #endif
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
                    let dot: CGFloat = 12
                    Circle()
                        .fill(Color(.systemGreen))
                        .frame(width: dot, height: dot)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
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

// MARK: - Peek preview shown when holding a conversation row

/// Static snapshot of the last few messages in a conversation, shown
/// as the `preview:` content of the row's context menu — Telegram /
/// Messenger style. Reads from `MessageCache` so a preview is only
/// rich when we've actually opened that conversation before;
/// otherwise falls back to `conversation.previewText`.
struct ConversationHoldPreview: View {
    let conversation: Conversation
    let myLogin: String?

    private var messages: [Message] {
        let cached = MessageCache.shared.get(conversation.id)?.messages ?? []
        // Only show real user messages, and take the most recent 8 so
        // the preview stays compact on small screens.
        let filtered = cached.filter { ($0.type ?? "user") == "user" && $0.unsent_at == nil }
        return Array(filtered.suffix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if messages.isEmpty {
                emptyBody
            } else {
                messageColumn
            }
        }
        .frame(width: 320, height: 380)
        // Background blur is provided by the UIVisualEffectView that
        // hosts this content (see CustomContextMenu.makePreviewVC).
        // Don't add a SwiftUI material here — it would render on top
        // of the blur and dilute it.
    }

    private var header: some View {
        HStack(spacing: 10) {
            if conversation.isGroup {
                GroupAvatarView(
                    name: conversation.group_name ?? conversation.displayTitle,
                    avatarURL: conversation.group_avatar_url,
                    groupId: conversation.id,
                    size: 36
                )
            } else {
                AvatarView(
                    url: conversation.displayAvatarURL,
                    size: 36,
                    login: conversation.other_user?.login
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if conversation.isGroup {
                    Text("\(conversation.participantsOrEmpty.count) members")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyBody: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(conversation.previewText ?? "No messages yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 16)
            Spacer()
        }
    }

    private var messageColumn: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(messages, id: \.id) { msg in
                    previewBubble(for: msg)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollDisabled(true)
        // ScrollView ships with an opaque systemBackground fill that
        // occludes our `.regularMaterial` backdrop. Hide it so the
        // blur reads through.
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    @ViewBuilder
    private func previewBubble(for msg: Message) -> some View {
        let isMe = msg.sender == myLogin
        HStack {
            if isMe { Spacer(minLength: 36) }
            bubble(for: msg, isMe: isMe)
            if !isMe { Spacer(minLength: 36) }
        }
    }

    @ViewBuilder
    private func bubble(for msg: Message, isMe: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isMe && conversation.isGroup {
                Text(msg.sender)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(bubbleText(for: msg))
                .font(.system(size: 13))
                .lineLimit(4)
                .foregroundStyle(isMe ? Color.white : Color(.label))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isMe ? Color("AccentColor") : Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func bubbleText(for msg: Message) -> String {
        if !msg.content.isEmpty { return msg.content }
        if (msg.attachments?.isEmpty == false) || msg.attachment_url != nil {
            return "📷 Photo"
        }
        return ""
    }
}

