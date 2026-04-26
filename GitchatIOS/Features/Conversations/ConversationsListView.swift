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
    @State private var profileResults: [FriendUser] = []
    @State private var isSearchingProfiles = false
    @State private var messageResults: [Message] = []
    @State private var isSearchingMessages = false
    @State private var searchTask: Task<Void, Never>?
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

    private var isSearching: Bool {
        !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredChats: [Conversation] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [Conversation]
        if q.isEmpty {
            base = vm.conversations
        } else {
            base = vm.conversations.filter { c in
                c.displayTitle.lowercased().contains(q)
                    || c.participantsOrEmpty.contains(where: { $0.login.lowercased().contains(q) })
            }
        }
        return base.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return (a.last_message_at ?? "") > (b.last_message_at ?? "")
        }
    }

    private func runSearch(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            profileResults = []
            messageResults = []
            isSearchingProfiles = false
            isSearchingMessages = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            isSearchingProfiles = true
            isSearchingMessages = true
            async let profiles = APIClient.shared.searchUsersForDM(query: q)
            async let messages = APIClient.shared.searchMessagesGlobal(q: q)
            if let p = try? await profiles, !Task.isCancelled { profileResults = p }
            isSearchingProfiles = false
            if let m = try? await messages, !Task.isCancelled { messageResults = m }
            isSearchingMessages = false
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
            // Pinned rows use no special background — pin icon in right column is sufficient
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
        .listRowSeparator(.hidden, edges: .top)
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(Color(.separator).opacity(0.4))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
        .alignmentGuide(.listRowSeparatorTrailing) { d in d.width }
        #if targetEnvironment(macCatalyst)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        #else
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        #endif
        .listRowBackground(rowBackground(for: convo))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                vm.markLocallyRead(convo.id)
                Task { try? await APIClient.shared.markRead(conversationId: convo.id) }
            } label: {
                Label("Read", systemImage: "envelope.open")
            }
            .tint(Color(.systemGreen))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmDelete = convo
            } label: {
                Label("Delete", systemImage: "trash")
            }
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

    @ViewBuilder
    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !profileResults.isEmpty || isSearchingProfiles {
                    sectionHeader("Profiles")
                    if isSearchingProfiles && profileResults.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.vertical, 16)
                    } else {
                        ForEach(profileResults) { user in
                            profileRow(user)
                            searchDivider
                        }
                    }
                }

                if !messageResults.isEmpty || isSearchingMessages {
                    sectionHeader("Messages")
                    if isSearchingMessages && messageResults.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.vertical, 16)
                    } else {
                        ForEach(messageResults) { msg in
                            messageSearchRow(msg)
                            searchDivider
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden, axes: .vertical)
        .overlay {
            if profileResults.isEmpty && !isSearchingProfiles
                && messageResults.isEmpty && !isSearchingMessages {
                ContentUnavailableCompat(
                    title: "",
                    systemImage: "magnifyingglass",
                    description: "No results. Try a different search."
                )
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private var searchDivider: some View {
        Color(.separator).opacity(0.4)
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.leading, 16 + 44 + 12) // padding + avatar + gap
    }

    @ViewBuilder
    private func profileRow(_ user: FriendUser) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                url: user.avatar_url,
                size: 44,
                login: user.login
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(user.login)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let name = user.name, !name.isEmpty {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            filter = ""
            if let convo = vm.conversations.first(where: { $0.other_user?.login == user.login }) {
                openConversation(convo)
            } else {
                Task {
                    if let convo = try? await APIClient.shared.createConversation(recipient: user.login) {
                        openConversation(convo)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageSearchRow(_ msg: Message) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                url: msg.sender_avatar,
                size: 44,
                login: msg.sender
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(msg.sender)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                highlightedText(msg.content, query: filter)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if let date = msg.created_at {
                Text(RelativeTime.chatListStamp(date))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let convoId = msg.conversation_id,
                  let convo = vm.conversations.first(where: { $0.id == convoId }) else { return }
            AppRouter.shared.pendingMessageId = msg.id
            filter = ""
            openConversation(convo)
        }
    }

    private func highlightedText(_ text: String, query: String) -> Text {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
              let range = text.range(of: q, options: .caseInsensitive) else {
            return Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        let before = String(text[text.startIndex..<range.lowerBound])
        let match = String(text[range])
        let after = String(text[range.upperBound..<text.endIndex])
        return Text(before).font(.subheadline).foregroundColor(.secondary)
            + Text(match).font(.subheadline.bold()).foregroundColor(.primary)
            + Text(after).font(.subheadline).foregroundColor(.secondary)
    }

    private var sidebar: some View {
        Group {
                if vm.isLoading && vm.conversations.isEmpty {
                    SkeletonList(count: 10, avatarSize: 64)
                } else if vm.conversations.isEmpty {
                    ContentUnavailableCompat(
                        title: "No conversations yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: "Tap the pencil icon to start one."
                    )
                } else if isSearching {
                    searchResultsList
                } else if filteredChats.isEmpty {
                    ContentUnavailableCompat(
                        title: "No results",
                        systemImage: "magnifyingglass",
                        description: "Try a different search."
                    )
                } else {
                    List {
                        ForEach(filteredChats) { convo in
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
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .onChange(of: filter) { runSearch($0) }
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
    /// 64pt on iOS for the Telegram-feeling chat-list look.
    private var avatarSize: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 44
        #else
        return 64
        #endif
    }

    private var metaFont: Font {
        .footnote
    }

    private var displayedUnread: Int {
        isLocallyRead ? 0 : conversation.unreadCount
    }

    /// Single cache lookup per row render — avoids repeated MessageCache.get() calls.
    private var cachedEntry: MessageCache.Entry? {
        MessageCache.shared.get(conversation.id)
    }

    /// Pull the most recent attachment URL out of the message cache so
    /// "📷 Photo" preview rows can show an actual thumbnail instead of
    /// the camera emoji.
    private var lastPhotoURL: URL? {
        guard let messages = cachedEntry?.messages,
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
        if let cached = cachedEntry?.messages,
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
                .lineLimit(1)
        } else if conversation.isGroup && isOutgoing && conversation.last_message != nil {
            // Group outgoing — "You:" prefix
            (Text("You: ").foregroundColor(Color("AccentColor")).font(.subheadline)
            + Text(previewWithoutPhotoEmoji).foregroundColor(secondaryTextColor).font(.subheadline))
            .lineLimit(1)
        } else {
            Text(previewWithoutPhotoEmoji)
                .font(.subheadline)
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
        }
    }

    private enum CheckmarkState {
        case none, sending, sent, read, failed
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseISO8601(_ s: String) -> Date? {
        isoFormatter.date(from: s) ?? isoFallbackFormatter.date(from: s)
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
        if let cache = cachedEntry {
            if conversation.isGroup {
                if let cursors = cache.readCursors, let msgDate = Self.parseISO8601(createdAt) {
                    let otherRead = cursors.contains { login, readAt in
                        guard login != AuthStore.shared.login,
                              let cursorDate = Self.parseISO8601(readAt) else { return false }
                        return cursorDate >= msgDate
                    }
                    if otherRead { return .read }
                }
            } else if let otherReadAt = cache.otherReadAt {
                if let readDate = Self.parseISO8601(otherReadAt),
                   let msgDate = Self.parseISO8601(createdAt),
                   readDate >= msgDate {
                    return .read
                }
            }
        }
        return .sent
    }

    private var accessibilityRowLabel: String {
        var parts: [String] = []
        parts.append(conversation.displayTitle)

        if let login = conversation.other_user?.login,
           PresenceStore.shared.isOnline(login) {
            parts.append("online")
        }

        if let draft = draftStore.draft(for: conversation.id) {
            parts.append("Draft: \(draft)")
        } else {
            let preview = conversation.previewText ?? ""
            if !preview.isEmpty { parts.append(preview) }
        }

        switch checkmarkState {
        case .sending: parts.append("Sending")
        case .sent: parts.append("Sent")
        case .read: parts.append("Read")
        case .failed: parts.append("Failed to send")
        case .none: break
        }

        if displayedUnread > 0 {
            parts.append("\(displayedUnread) unread message\(displayedUnread == 1 ? "" : "s")")
        }
        if hasMention { parts.append("You were mentioned") }
        if isMuted { parts.append("Muted") }
        if conversation.isPinned { parts.append("Pinned") }

        return parts.joined(separator: ". ")
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
                // Row 1: Name + Checkmark + Date
                HStack(spacing: 4) {
                    Text(conversation.displayTitle)
                        .font(displayedUnread > 0 ? .headline : .body)
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    checkmarkView
                    Text(RelativeTime.chatListStamp(conversation.last_message_at))
                        .font(metaFont)
                        .foregroundStyle(displayedUnread > 0 && !isActive ? Color("AccentColor") : secondaryTextColor)
                        .instantTooltip(ChatMessageText.fullTimestamp(conversation.last_message_at))
                        .layoutPriority(1)
                }
                // Row 2: Sender (group) or Preview + right indicators
                HStack(alignment: .bottom, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let sender = lastSenderLogin, !isOutgoing {
                            HStack(spacing: 4) {
                                senderAvatarView(for: sender)
                                Text(sender)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                        HStack(alignment: .top, spacing: 4) {
                            if let draft = draftStore.draft(for: conversation.id) {
                                (Text("Draft: ").foregroundColor(Color(.systemRed)).font(.subheadline)
                                + Text(draft).foregroundColor(secondaryTextColor).font(.subheadline))
                                .lineLimit(1)
                                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
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
                    Spacer(minLength: 4)
                    rightIndicators
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRowLabel)
        #if targetEnvironment(macCatalyst)
        .padding(.horizontal, macRowHorizontalPadding)
        .padding(.vertical, macRowVerticalPadding)
        #else
        .padding(.vertical, 12)
        #endif
    }

    @ViewBuilder
    private var checkmarkView: some View {
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
    }

    @ViewBuilder
    private var rightIndicators: some View {
        HStack(spacing: 4) {
            if displayedUnread > 0 {
                if hasMention {
                    Text("@")
                        .font(.caption.bold())
                        .frame(width: 20, height: 20)
                        .background(Color("AccentColor"), in: Circle())
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
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
                    .transition(.scale.combined(with: .opacity))
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
            }
        }
        .animation(.spring(response: 0.3), value: displayedUnread)
        .animation(.spring(response: 0.3), value: hasMention)
    }

    @ViewBuilder
    private func senderAvatarView(for sender: String) -> some View {
        let url: URL? = {
            if let p = conversation.participantsOrEmpty.first(where: { $0.login == sender }),
               let urlStr = p.avatar_url, let u = URL(string: urlStr) { return u }
            if let urlStr = conversation.last_message?.sender_avatar,
               let u = URL(string: urlStr) { return u }
            if let cached = cachedEntry?.messages,
               let msg = cached.last(where: { $0.sender == sender }),
               let urlStr = msg.sender_avatar, let u = URL(string: urlStr) { return u }
            return URL(string: "https://github.com/\(sender).png")
        }()
        if let url {
            CachedAsyncImage(url: url, contentMode: .fill, maxPixelSize: 60)
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
            .accessibilityHidden(true)
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
        if #available(iOS 17, *), !title.isEmpty {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
        } else {
            VStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 48)).foregroundStyle(.secondary)
                if !title.isEmpty {
                    Text(title).font(.title3.bold())
                }
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
        HStack(spacing: 12) {
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
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if conversation.isGroup {
                    Text("\(conversation.participantsOrEmpty.count) members")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            VStack(spacing: 4) {
                ForEach(messages, id: \.id) { msg in
                    previewBubble(for: msg)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
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
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(bubbleText(for: msg))
                .font(.footnote)
                .lineLimit(4)
                .foregroundStyle(isMe ? Color.white : Color(.label))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

// MARK: - Custom Swipe Actions (Telegram-style full-height blocks)

struct SwipeAction {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
}

struct CustomSwipeRow<Content: View>: View {
    let leadingActions: [SwipeAction]
    let trailingActions: [SwipeAction]
    let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var prevOffset: CGFloat = 0
    @GestureState private var isDragging = false

    private let actionWidth: CGFloat = 74
    private var trailingWidth: CGFloat { CGFloat(trailingActions.count) * actionWidth }
    private var leadingWidth: CGFloat { CGFloat(leadingActions.count) * actionWidth }

    var body: some View {
        ZStack(alignment: .leading) {
            // Leading actions (swipe right)
            if offset > 0 && !leadingActions.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(leadingActions.enumerated()), id: \.offset) { _, action in
                        actionBlock(action)
                    }
                }
                .frame(width: max(offset, 0))
                .clipped()
            }

            // Trailing actions (swipe left)
            if offset < 0 && !trailingActions.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(trailingActions.reversed().enumerated()), id: \.offset) { _, action in
                        actionBlock(action)
                    }
                }
                .frame(width: max(-offset, 0))
                .clipped()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            // Content
            content()
                .offset(x: offset)
                .background(Color(.systemBackground))
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .updating($isDragging) { _, state, _ in state = true }
                .onChanged { value in
                    let translation = value.translation.width + prevOffset
                    if leadingActions.isEmpty && translation > 0 { return }
                    if trailingActions.isEmpty && translation < 0 { return }
                    offset = translation
                }
                .onEnded { value in
                    let velocity = value.predictedEndTranslation.width - value.translation.width
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        if offset > leadingWidth / 2 || velocity > 100 {
                            // Full swipe right — trigger first leading action
                            if let first = leadingActions.first {
                                first.action()
                            }
                            offset = 0
                        } else if offset < -trailingWidth / 2 {
                            // Snap open trailing
                            offset = -trailingWidth
                        } else {
                            offset = 0
                        }
                        prevOffset = offset
                    }
                }
        )
        .onChange(of: isDragging) { dragging in
            if !dragging && offset != -trailingWidth && offset != 0 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    offset = 0
                    prevOffset = 0
                }
            }
        }
    }

    private func actionBlock(_ action: SwipeAction) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                offset = 0
                prevOffset = 0
            }
            action.action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: action.icon)
                    .font(.system(size: 20))
                Text(action.title)
                    .font(.caption2)
            }
            .foregroundStyle(.white)
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .background(action.color)
        }
        .buttonStyle(.plain)
    }
}

private struct SectionSpacingModifier: ViewModifier {
    let spacing: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.listSectionSpacing(spacing)
        } else {
            content
        }
    }
}

