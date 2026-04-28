import SwiftUI
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var pinnedIds: Set<String> = []
    /// Full pinned Message objects for the banner — independent of pagination.
    @Published var pinnedMessages: [Message] = []
    @Published var typingUsers: Set<String> = []
    @Published var otherReadAt: String?
    @Published var readCursors: [String: String] = [:]
    @Published var isLoading = false
    @Published var isSyncing = false
    @Published var isMuted: Bool = false
    @Published var draft = "" {
        didSet { saveDraft() }
    }
    @Published var replyingTo: Message?
    @Published var editingMessage: Message?
    @Published var error: String?
    @Published var uploading = false
    @Published var nextCursor: String?
    @Published var isLoadingMore = false

    @Published private(set) var target: ChatTarget

    /// Legacy accessor. Returns the underlying `Conversation` for `.conversation`
    /// targets and the parent conversation for `.topic` targets — sufficient for
    /// every existing read site (draft key, mute lookup, participant list, etc.).
    var conversation: Conversation {
        switch target {
        case .conversation(let c): return c
        case .topic(_, let p):     return p
        }
    }

    private var draftKey: String { "gitchat.draft.\(conversation.id)" }

    // MARK: - Pending message topic context

    /// Derives (parentID, topicID) from the active target for use when
    /// constructing `OutboxStore.PendingMessage`. Both values are nil for
    /// plain-conversation targets so old pending items decode cleanly.
    private var pendingTopicContext: (parentID: String?, topicID: String?) {
        switch target {
        case .conversation: return (nil, nil)
        case .topic(let t, let p): return (p.id, t.id)
        }
    }

    // MARK: - Endpoint resolution

    var sendEndpoint: String {
        switch target {
        case .conversation(let c):
            return "messages/conversations/\(c.id)"
        case .topic(let t, let p):
            return "messages/conversations/\(p.id)/topics/\(t.id)/messages"
        }
    }

    var fetchEndpoint: String {
        switch target {
        case .conversation(let c):
            return "messages/conversations/\(c.id)"
        case .topic(let t, let p):
            return "messages/conversations/\(p.id)/topics/\(t.id)/messages"
        }
    }

    #if DEBUG
    var testHook_sendEndpoint: String { sendEndpoint }
    #endif

    // MARK: - Topic event observer

    private var topicEventObserver: NSObjectProtocol?

    private func observeTopicEvents() {
        guard topicEventObserver == nil else { return }
        topicEventObserver = NotificationCenter.default.addObserver(
            forName: .gitchatTopicEvent, object: nil, queue: .main
        ) { [weak self] note in
            guard let evt = note.object as? TopicSocketEvent else { return }
            Task { @MainActor [weak self] in
                self?.handle(topicEvent: evt)
            }
        }
    }

    private func handle(topicEvent evt: TopicSocketEvent) {
        switch evt {
        case .message(let parentId, let topicId, let message):
            ConversationsCache.shared.patchLastMessage(
                conversationId: parentId,
                text: message.content.isEmpty ? nil : message.content,
                at: message.created_at
            )
            if target.conversationId == topicId {
                guard ChatMessageView.seenIds.insert(message.id).inserted else { return }
                messages.append(message)
            } else {
                TopicListStore.shared.bumpUnread(topicId: topicId, parentId: parentId, by: 1)
            }
        case .archived(let parentId, let topicId):
            if target.conversationId == topicId {
                ToastCenter.shared.show(.info, "This topic was archived", nil)
                Task { await switchTargetAfterArchive(parentId: parentId) }
            }
        case .settingsUpdated(let parentId, let topicsEnabled):
            if target.parentConversationId == parentId, !topicsEnabled {
                ToastCenter.shared.show(.info, "Topics disabled by admin", nil)
                if case .topic(_, let parent) = target {
                    setTarget(.conversation(parent))
                }
            }
        default:
            break
        }
    }

    private func switchTargetAfterArchive(parentId: String) async {
        guard case .topic(_, let parent) = target else { return }
        do {
            let topics = try await APIClient.shared.fetchTopics(parentId: parent.id)
            guard case .topic = target else { return }    // user already moved on
            if let general = topics.first(where: { $0.is_general }) {
                setTarget(.topic(general, parent: parent))
            } else {
                setTarget(.conversation(parent))
            }
        } catch {
            guard case .topic = target else { return }
            setTarget(.conversation(parent))
        }
    }

    private var loadGeneration: Int = 0

    func setTarget(_ newTarget: ChatTarget) {
        guard newTarget.conversationId != target.conversationId else { return }
        loadGeneration &+= 1
        self.target = newTarget
        self.messages = []
        Task { await self.load() }
    }

    deinit {
        topicEventObserver.map(NotificationCenter.default.removeObserver)
    }

    init(target: ChatTarget) {
        self.target = target
        let conv: Conversation
        switch target {
        case .conversation(let c): conv = c
        case .topic(_, let p):     conv = p
        }
        self.isMuted = conv.is_muted == true
        if let saved = UserDefaults.standard.string(forKey: "gitchat.draft.\(conv.id)") {
            self.draft = saved
        }
        if let cached = MessageCache.shared.get(conv.id) {
            self.messages = cached.messages
            self.nextCursor = cached.nextCursor
            self.otherReadAt = cached.otherReadAt
            if let cursors = cached.readCursors {
                self.readCursors = cursors
            }
            ChatMessageView.markSeen(cached.messages.map(\.id))
        }
        observeTopicEvents()
    }

    // MARK: - Render-time merge (pending + server)

    /// Server-confirmed messages merged with currently-pending sends from
    /// the global outbox. Re-evaluated every render. Used by the message
    /// list rendering path; non-render reads (search, pinned list, scroll
    /// targeting) stay on `messages` because those operate on
    /// server-confirmed messages only.
    ///
    /// `created_at` is an ISO8601 string; lexicographic `<` sorts these
    /// chronologically.
    var visibleMessages: [Message] {
        let pending = OutboxStore.shared.pendingFor(target.conversationId)
            .map(OutboxStore.shared.toMessage)
        guard !pending.isEmpty else { return messages }
        return (messages + pending).sorted {
            ($0.created_at ?? "") < ($1.created_at ?? "")
        }
    }

    private func saveDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(draft, forKey: draftKey)
        }
        NotificationCenter.default.post(
            name: DraftStore.draftChangedNotification,
            object: nil,
            userInfo: ["conversationId": conversation.id]
        )
    }

    // MARK: - Loading

    func load() async {
        let myGen = loadGeneration
        let hadCache = !messages.isEmpty
        if !hadCache { isLoading = true }
        // Only show "syncing" when there's no cached data — returning
        // users see the cached list instantly with no subtitle flicker.
        if !hadCache { isSyncing = true }
        defer {
            isLoading = false
            isSyncing = false
        }
        do {
            let resp = try await APIClient.shared.getMessages(at: fetchEndpoint)
            guard myGen == loadGeneration else { return }
            let fetched = resp.messages.reversed()
            // Merge the fetched newest page into our (possibly larger)
            // cached list instead of overwriting it. This preserves
            // older pages that the user already paged into via
            // scroll-up in a previous session.
            if messages.isEmpty {
                self.messages = Array(fetched)
                self.nextCursor = resp.nextCursor
                // Mark the initial page as already-seen so bubbles
                // don't all pop in on first entry — only newly arrived
                // messages should animate in.
                ChatMessageView.markSeen(self.messages.map(\.id))
            } else {
                var existing = messages
                let existingIds = Set(existing.map(\.id))
                // Replace edited/updated rows in place.
                let fetchedById = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
                for i in existing.indices {
                    if let updated = fetchedById[existing[i].id] {
                        existing[i] = updated
                    }
                }
                // Append truly new (newer than cache) messages.
                let newOnes = fetched.filter { !existingIds.contains($0.id) }
                existing.append(contentsOf: newOnes)
                self.messages = existing
                // nextCursor stays as-is — we still know about older
                // pages from the previous session.
            }
            self.otherReadAt = resp.otherReadAt
            if let cursors = resp.readCursors {
                for c in cursors { readCursors[c.login] = c.readAt }
            }
            persistCache()
            try? await APIClient.shared.markRead(conversationId: conversation.id)
        } catch { self.error = error.localizedDescription }
        await loadPinned()
    }

    func loadMoreIfNeeded() async {
        guard !isLoadingMore, let cursor = nextCursor else { return }
        let myGen = loadGeneration
        isLoadingMore = true; defer { isLoadingMore = false }
        do {
            let resp = try await APIClient.shared.getMessages(
                at: fetchEndpoint, cursor: cursor
            )
            guard myGen == loadGeneration else { return }
            let older = resp.messages.reversed()
            let known = Set(messages.map(\.id))
            let deduped = older.filter { !known.contains($0.id) }
            // Older paginated messages should appear immediately, not
            // pop in — mark them seen before they hit the UI.
            ChatMessageView.markSeen(deduped.map(\.id))
            messages.insert(contentsOf: deduped, at: 0)
            nextCursor = resp.nextCursor
            persistCache()
        } catch { }
        await loadPinned()
    }

    private func persistCache() {
        MessageCache.shared.store(conversation.id, entry: MessageCache.Entry(
            messages: self.messages,
            nextCursor: self.nextCursor,
            otherReadAt: self.otherReadAt,
            readCursors: self.readCursors.isEmpty ? nil : self.readCursors,
            fetchedAt: Date()
        ))
    }

    func seenByLogins(for message: Message) -> [String] {
        guard conversation.isGroup else { return [] }
        let msgDate = message.created_at ?? ""
        return readCursors.compactMap { login, readAt in
            readAt >= msgDate ? login : nil
        }.sorted()
    }

    func seenCursorLogins(for message: Message, nextCreatedAt: String?) -> [String] {
        guard conversation.isGroup, !readCursors.isEmpty else { return [] }
        let msgDate = message.created_at ?? ""
        return readCursors.compactMap { login, readAt in
            guard readAt >= msgDate else { return nil }
            if let nextDate = nextCreatedAt, readAt >= nextDate { return nil }
            return login
        }.sorted()
    }

    /// Load pages until the target message is in `messages`, then return true.
    /// Returns false if we exhaust all pages without finding it.
    ///
    /// Optimization: if a `createdAt` hint is provided (e.g. from a search
    /// result), use it as cursor to jump directly to the page containing the
    /// message instead of paging sequentially from the latest.
    func ensureMessageLoaded(id: String, createdAt: String? = nil) async -> Bool {
        if messages.contains(where: { $0.id == id }) { return true }

        // Fast path: jump directly using createdAt as cursor.
        // Backend pagination is exclusive (messages strictly BEFORE cursor),
        // so bump the cursor forward by 1 second to ensure the target
        // message itself is included in the response.
        if let createdAt {
            let cursor = Self.offsetCursor(createdAt, bySeconds: 1)
            do {
                let resp = try await APIClient.shared.getMessages(
                    at: fetchEndpoint, cursor: cursor, limit: 50
                )
                let page = resp.messages.reversed()
                let known = Set(messages.map(\.id))
                let deduped = Array(page.filter { !known.contains($0.id) })
                if !deduped.isEmpty {
                    ChatMessageView.markSeen(deduped.map(\.id))
                    // Insert in sorted position
                    let insertIdx = messages.firstIndex {
                        ($0.created_at ?? "") > (deduped.first?.created_at ?? "")
                    } ?? 0
                    messages.insert(contentsOf: deduped, at: insertIdx)
                    persistCache()
                }
                if messages.contains(where: { $0.id == id }) { return true }
            } catch { }
        }

        // Slow fallback: page backward sequentially.
        var cursor = nextCursor
        var attempts = 0
        while let c = cursor, attempts < 10 {
            attempts += 1
            do {
                let resp = try await APIClient.shared.getMessages(
                    at: fetchEndpoint, cursor: c
                )
                let older = resp.messages.reversed()
                let known = Set(messages.map(\.id))
                let deduped = older.filter { !known.contains($0.id) }
                ChatMessageView.markSeen(deduped.map(\.id))
                messages.insert(contentsOf: deduped, at: 0)
                nextCursor = resp.nextCursor
                cursor = resp.nextCursor
                persistCache()
                if messages.contains(where: { $0.id == id }) { return true }
                if resp.nextCursor == nil { break }
            } catch { break }
        }
        return false
    }

    /// Bump an ISO-8601 cursor string forward by `seconds` so that
    /// exclusive cursor pagination includes the row at the original
    /// timestamp. Falls back to the original string if parsing fails.
    private static func offsetCursor(_ iso: String, bySeconds seconds: Int) -> String {
        let fmt = ISO8601DateFormatter()
        // Accept both fractional-seconds and plain ISO strings.
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fmt.date(from: iso) {
            return fmt.string(from: date.addingTimeInterval(TimeInterval(seconds)))
        }
        fmt.formatOptions = [.withInternetDateTime]
        if let date = fmt.date(from: iso) {
            let fmtOut = ISO8601DateFormatter()
            fmtOut.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fmtOut.string(from: date.addingTimeInterval(TimeInterval(seconds)))
        }
        return iso
    }

    func loadPinned() async {
        do {
            let pins = try await APIClient.shared.pinnedMessages(conversationId: conversation.id)
            self.pinnedIds = Set(pins.map(\.id))
            self.pinnedMessages = pins
        } catch { }
    }

    // MARK: - Send / edit / delete

    func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        UserDefaults.standard.removeObject(forKey: draftKey)
        let replyId = replyingTo?.id
        replyingTo = nil
        AnalyticsTracker.trackMessageSent(
            conversationId: conversation.id,
            isGroup: conversation.isGroup,
            hasAttachment: false
        )
        do {
            if let editing = editingMessage {
                try await APIClient.shared.editMessage(
                    conversationId: conversation.id,
                    messageId: editing.id,
                    body: body
                )
                if let idx = messages.firstIndex(where: { $0.id == editing.id }) {
                    messages[idx] = Message(
                        id: editing.id,
                        conversation_id: editing.conversation_id,
                        sender: editing.sender,
                        sender_avatar: editing.sender_avatar,
                        content: body,
                        created_at: editing.created_at,
                        edited_at: ISO8601DateFormatter().string(from: Date()),
                        reactions: editing.reactions,
                        attachment_url: editing.attachment_url,
                        type: editing.type,
                        reply_to_id: editing.reply_to_id
                    )
                }
                editingMessage = nil
            } else {
                let ctx = pendingTopicContext
                let pending = OutboxStore.PendingMessage(
                    localID: "local-\(UUID().uuidString)",
                    conversationID: target.conversationId,
                    senderLogin: AuthStore.shared.login ?? "me",
                    senderAvatar: nil,
                    content: body,
                    replyToID: replyId,
                    createdAt: Date(),
                    state: .sending,
                    topicID: ctx.topicID,
                    parentConversationID: ctx.parentID
                )
                OutboxStore.shared.enqueue(pending)
                Haptics.impact(.light)
                OutboxStore.shared.runSend(for: pending)
            }
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
            ToastCenter.shared.show(.error, "Send failed", error.localizedDescription)
        }
    }

    /// Synchronous optimistic reaction update — so double-tap renders
    /// the heart instantly, before any async hop.
    func applyOptimisticReaction(messageId: String, emoji: String, myLogin: String?) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        var existing = messages[idx].reactions ?? []
        if let ri = existing.firstIndex(where: { $0.emoji == emoji }) {
            let r = existing[ri]
            existing[ri] = MessageReaction(emoji: emoji, count: r.count + 1, reacted: true)
        } else {
            existing.append(MessageReaction(emoji: emoji, count: 1, reacted: true))
        }
        let m = messages[idx]
        messages[idx] = Message(
            id: m.id,
            conversation_id: m.conversation_id,
            sender: m.sender,
            sender_avatar: m.sender_avatar,
            content: m.content,
            created_at: m.created_at,
            edited_at: m.edited_at,
            reactions: existing,
            attachment_url: m.attachment_url,
            type: m.type,
            reply_to_id: m.reply_to_id,
            reply: m.reply,
            attachments: m.attachments,
            unsent_at: m.unsent_at,
            reactionRows: (m.reactionRows ?? []) + [RawReactionRow(emoji: emoji, user_login: myLogin)]
        )
    }

    func removeOptimisticReaction(messageId: String, emoji: String, myLogin: String?) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        var existing = messages[idx].reactions ?? []
        if let ri = existing.firstIndex(where: { $0.emoji == emoji }) {
            let r = existing[ri]
            if r.count <= 1 {
                existing.remove(at: ri)
            } else {
                existing[ri] = MessageReaction(emoji: emoji, count: r.count - 1, reacted: false)
            }
        }
        let m = messages[idx]
        var rows = m.reactionRows ?? []
        if let rowIdx = rows.firstIndex(where: { $0.emoji == emoji && $0.user_login == myLogin }) {
            rows.remove(at: rowIdx)
        }
        messages[idx] = Message(
            id: m.id, conversation_id: m.conversation_id,
            sender: m.sender, sender_avatar: m.sender_avatar,
            content: m.content, created_at: m.created_at,
            edited_at: m.edited_at, reactions: existing.isEmpty ? nil : existing,
            attachment_url: m.attachment_url, type: m.type,
            reply_to_id: m.reply_to_id, reply: m.reply,
            attachments: m.attachments, unsent_at: m.unsent_at,
            reactionRows: rows
        )
    }

    func react(messageId: String, emoji: String, myLogin: String? = nil) async {
        // Optimistic: bump the count (or add a new chip) on the local message immediately.
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            var existing = messages[idx].reactions ?? []
            if let ri = existing.firstIndex(where: { $0.emoji == emoji }) {
                let r = existing[ri]
                existing[ri] = MessageReaction(emoji: emoji, count: r.count + 1, reacted: true)
            } else {
                existing.append(MessageReaction(emoji: emoji, count: 1, reacted: true))
            }
            let m = messages[idx]
            messages[idx] = Message(
                id: m.id,
                conversation_id: m.conversation_id,
                sender: m.sender,
                sender_avatar: m.sender_avatar,
                content: m.content,
                created_at: m.created_at,
                edited_at: m.edited_at,
                reactions: existing,
                attachment_url: m.attachment_url,
                type: m.type,
                reply_to_id: m.reply_to_id,
                reply: m.reply,
                attachments: m.attachments,
                unsent_at: m.unsent_at,
                reactionRows: (m.reactionRows ?? []) + [RawReactionRow(emoji: emoji, user_login: myLogin)]
            )
        }
        try? await APIClient.shared.react(messageId: messageId, emoji: emoji, add: true)
    }

    func delete(_ msg: Message) async {
        do {
            try await APIClient.shared.deleteMessage(conversationId: conversation.id, messageId: msg.id)
            messages.removeAll { $0.id == msg.id }
        } catch { self.error = error.localizedDescription }
    }

    /// Patch the locally-held Conversation with fresh group metadata so
    /// the header (title / avatar) updates immediately after a save. BE
    /// will also emit `conversation:updated` so the list refresh covers
    /// other devices; this path covers the "just edited on this device"
    /// race where the user is still looking at the stale header.
    func applyLocalMetadata(name: String?, avatarUrl: String?) {
        let c = conversation
        target = .conversation(Conversation(
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
            is_muted: c.is_muted,
            has_mention: c.has_mention,
            has_reaction: c.has_reaction,
            topics_enabled: c.topics_enabled,
            has_topics: c.has_topics,
            topic_chips: c.topic_chips
        ))
    }

    func toggleMute() async {
        // Flip optimistically so the menu label updates instantly.
        let wasMuted = isMuted
        isMuted.toggle()
        if isMuted {
            MutedConversationsStore.insert(conversation.id)
        } else {
            MutedConversationsStore.remove(conversation.id)
        }
        do {
            if wasMuted {
                try await APIClient.shared.unmuteConversation(id: conversation.id)
                ToastCenter.shared.show(.info, "Unmuted")
            } else {
                try await APIClient.shared.muteConversation(id: conversation.id)
                ToastCenter.shared.show(.success, "Muted")
            }
        } catch {
            isMuted = wasMuted
            if wasMuted {
                MutedConversationsStore.insert(conversation.id)
            } else {
                MutedConversationsStore.remove(conversation.id)
            }
            ToastCenter.shared.show(.error, "Mute failed", error.localizedDescription)
        }
    }

    func togglePin(_ msg: Message) async {
        let wasPinned = pinnedIds.contains(msg.id)
        // Flip locally first so the UI updates instantly; revert if the
        // API call fails.
        if wasPinned {
            pinnedIds.remove(msg.id)
            pinnedMessages.removeAll { $0.id == msg.id }
        } else {
            pinnedIds.insert(msg.id)
            pinnedMessages.append(msg)
        }
        Haptics.impact(.light)
        do {
            if wasPinned {
                try await APIClient.shared.unpinMessage(conversationId: conversation.id, messageId: msg.id)
                ToastCenter.shared.show(.info, "Unpinned message")
            } else {
                try await APIClient.shared.pinMessage(conversationId: conversation.id, messageId: msg.id)
                ToastCenter.shared.show(.success, "Pinned message")
            }
        } catch {
            // Revert on failure
            if wasPinned {
                pinnedIds.insert(msg.id)
                pinnedMessages.append(msg)
            } else {
                pinnedIds.remove(msg.id)
                pinnedMessages.removeAll { $0.id == msg.id }
            }
            ToastCenter.shared.show(.error, "Couldn't pin", error.localizedDescription)
        }
    }

    func startEdit(_ msg: Message) {
        editingMessage = msg
        draft = msg.content
        replyingTo = nil
    }

    func cancelEdit() {
        editingMessage = nil
        draft = ""
    }

    func unsend(_ msg: Message) async {
        do {
            try await APIClient.shared.unsendMessage(messageId: msg.id)
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                messages.remove(at: idx)
            }
            ToastCenter.shared.show(.info, "Unsent")
        } catch {
            ToastCenter.shared.show(.error, "Couldn't unsend", error.localizedDescription)
        }
    }

    // MARK: - Attachments

    func uploadAndSendMany(items: [(Data, String, String)], senderLogin: String?, caption: String = "") async {
        guard !items.isEmpty else { return }
        var compressed: [(Data, String, String)] = []
        compressed.reserveCapacity(items.count)
        for item in items {
            compressed.append(
                await Self.compressIfImageOffMain(data: item.0, filename: item.1, mimeType: item.2)
            )
        }
        await sendEncodedAttachments(compressed, senderLogin: senderLogin, caption: caption)
    }

    /// UIImage entry point for drop/paste/picker flows. Encodes each image
    /// exactly once, off MainActor, then hands off to the shared upload
    /// pipeline. Avoids the previous pattern where the caller would
    /// `jpegData(...)` on MainActor and `uploadAndSendMany` would then
    /// decode + re-encode via `compressIfImage`.
    func uploadImagesAndSend(images: [UIImage], senderLogin: String?, caption: String = "") async {
        guard !images.isEmpty else { return }
        var encoded: [(Data, String, String)] = []
        encoded.reserveCapacity(images.count)
        for (i, img) in images.enumerated() {
            if let tuple = await Self.encodeForUploadOffMain(image: img, filename: "image-\(i).jpg") {
                encoded.append(tuple)
            }
        }
        await sendEncodedAttachments(encoded, senderLogin: senderLogin, caption: caption)
    }

    private func sendEncodedAttachments(
        _ encoded: [(Data, String, String)],
        senderLogin: String?,
        caption: String = ""
    ) async {
        guard !encoded.isEmpty else { return }
        AnalyticsTracker.trackMessageSent(
            conversationId: conversation.id,
            isGroup: conversation.isGroup,
            hasAttachment: true
        )
        var localURLs: [URL] = []
        var localAttachments: [MessageAttachment] = []
        for (data, filename, _) in encoded {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(filename)")
            try? data.write(to: tmpURL)
            localURLs.append(tmpURL)
            localAttachments.append(MessageAttachment(
                attachment_id: nil, url: tmpURL.absoluteString, type: "image",
                filename: filename, mime_type: "image/jpeg",
                width: nil, height: nil
            ))
        }
        let localID = "local-\(UUID().uuidString)"
        let optimistic = Message(
            id: localID,
            conversation_id: conversation.id,
            sender: senderLogin ?? "me",
            sender_avatar: nil,
            content: caption,
            created_at: ISO8601DateFormatter().string(from: Date()),
            edited_at: nil,
            reactions: nil,
            attachment_url: nil,
            type: "user",
            reply_to_id: nil,
            attachments: localAttachments
        )
        messages.append(optimistic)
        Haptics.impact(.light)

        do {
            let urls = try await withThrowingTaskGroup(of: (Int, String).self) { group -> [String] in
                for (i, tuple) in encoded.enumerated() {
                    group.addTask {
                        let url = try await APIClient.shared.uploadAttachment(
                            data: tuple.0,
                            filename: tuple.1,
                            mimeType: tuple.2,
                            conversationId: self.conversation.id
                        )
                        return (i, url)
                    }
                }
                var result = Array(repeating: "", count: encoded.count)
                for try await (i, url) in group { result[i] = url }
                return result
            }
            let msg = try await APIClient.shared.sendMessage(
                at: sendEndpoint,
                body: caption,
                attachmentURLs: urls
            )
            // Honor the seenIds dedupe contract that the WebSocket
            // and OutboxStore handlers also follow (ChatDetailView
            // lines ~719 and ~728). If the WebSocket already delivered
            // this message and appended it to `messages`, the optimistic
            // entry is now alongside it — replacing the optimistic with
            // `msg` would produce two entries with the same id and crash
            // UIDiffableDataSource at snapshot time. Branch on insert
            // result: first sighting → replace; already-seen → drop the
            // optimistic.
            if ChatMessageView.seenIds.insert(msg.id).inserted {
                if let idx = messages.firstIndex(where: { $0.id == localID }) {
                    messages[idx] = msg
                }
            } else {
                messages.removeAll { $0.id == localID }
            }
            for u in localURLs { try? FileManager.default.removeItem(at: u) }
        } catch {
            messages.removeAll { $0.id == localID }
            ToastCenter.shared.show(.error, "Upload failed", error.localizedDescription)
        }
    }

    func uploadAndSend(data: Data, filename: String, mimeType: String, senderLogin: String?) async {
        let (compressed, usedFilename, usedMime) = await Self.compressIfImageOffMain(
            data: data, filename: filename, mimeType: mimeType
        )
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(usedFilename)")
        try? compressed.write(to: tmpURL)
        let localID = "local-\(UUID().uuidString)"
        let optimistic = Message(
            id: localID,
            conversation_id: conversation.id,
            sender: senderLogin ?? "me",
            sender_avatar: nil,
            content: "",
            created_at: ISO8601DateFormatter().string(from: Date()),
            edited_at: nil,
            reactions: nil,
            attachment_url: tmpURL.absoluteString,
            type: "user",
            reply_to_id: nil
        )
        messages.append(optimistic)
        Haptics.impact(.light)

        do {
            let url = try await APIClient.shared.uploadAttachment(
                data: compressed,
                filename: usedFilename,
                mimeType: usedMime,
                conversationId: conversation.id
            )
            let msg = try await APIClient.shared.sendMessage(
                at: sendEndpoint,
                body: "",
                attachmentURL: url
            )
            // See note in `sendEncodedAttachments`. If the WebSocket
            // raced ahead, the message is already in `messages`; drop
            // the optimistic instead of replacing.
            if ChatMessageView.seenIds.insert(msg.id).inserted {
                if let idx = messages.firstIndex(where: { $0.id == localID }) {
                    messages[idx] = msg
                } else {
                    messages.append(msg)
                }
            } else {
                messages.removeAll { $0.id == localID }
            }
            try? FileManager.default.removeItem(at: tmpURL)
        } catch {
            self.error = error.localizedDescription
            messages.removeAll { $0.id == localID }
            ToastCenter.shared.show(.error, "Upload failed", error.localizedDescription)
        }
    }

    nonisolated private static func compressIfImage(
        data: Data, filename: String, mimeType: String
    ) -> (Data, String, String) {
        // Animated GIFs flatten to a single frame when rendered via
        // UIImage, so we pass them through untouched. BE/CDN will serve
        // them at original size; they're rarely large enough to need
        // compression anyway.
        if mimeType == "image/gif" {
            return (data, filename, mimeType)
        }
        guard mimeType.hasPrefix("image/"), let image = UIImage(data: data) else {
            return (data, filename, mimeType)
        }
        let resized = resizeForUpload(image)
        if let jpeg = resized.jpegData(compressionQuality: 0.75) {
            let base = (filename as NSString).deletingPathExtension
            return (jpeg, "\(base).jpg", "image/jpeg")
        }
        return (data, filename, mimeType)
    }

    /// Shared resize helper — used both by `compressIfImage` and by the
    /// drop/paste path (which encodes UIImage → Data directly and would
    /// otherwise skip the max-dim clamp in compressIfImage).
    /// `UIGraphicsImageRenderer` respects `image.imageOrientation`, so
    /// portrait photos stay portrait.
    nonisolated static func resizeForUpload(_ image: UIImage, maxDim: CGFloat = 1600) -> UIImage {
        let size = image.size
        let scale = min(1, maxDim / max(size.width, size.height))
        guard scale < 1 else { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Async wrapper that runs `compressIfImage` on a utility-priority
    /// detached task so `UIImage.jpegData` and `UIGraphicsImageRenderer`
    /// don't block MainActor while the user is still looking at the chat.
    nonisolated static func compressIfImageOffMain(
        data: Data, filename: String, mimeType: String
    ) async -> (Data, String, String) {
        await Task.detached(priority: .utility) {
            compressIfImage(data: data, filename: filename, mimeType: mimeType)
        }.value
    }

    /// Async wrapper for the drop/paste path that takes an in-memory
    /// UIImage, resizes it, and encodes a single JPEG — all off MainActor.
    /// Avoids the previous "encode twice" pattern where the drop handler
    /// would JPEG-encode before calling `uploadAndSendMany`, which then
    /// decoded and re-encoded via `compressIfImage`.
    nonisolated static func encodeForUploadOffMain(
        image: UIImage, filename: String
    ) async -> (Data, String, String)? {
        await Task.detached(priority: .utility) {
            let resized = resizeForUpload(image)
            guard let jpeg = resized.jpegData(compressionQuality: 0.75) else { return nil }
            return (jpeg, filename, "image/jpeg")
        }.value
    }

}

// MARK: - Convenience init + target mutation

extension ChatViewModel {
    convenience init(conversation: Conversation) {
        self.init(target: .conversation(conversation))
    }

    /// Replace the current target's conversation with a refreshed copy.
    /// Used by `syncMutedFromCache` and similar call sites that receive
    /// an updated `Conversation` from the cache or WebSocket and need
    /// to propagate it into the view model.
    func updateConversation(_ conv: Conversation) {
        // Only refresh when the target is already .conversation. When Task 2
        // adds .topic, callers that need to refresh the parent of an active
        // topic should use a dedicated method added in that task — silently
        // demoting a .topic target to .conversation here would lose the
        // topic context.
        guard case .conversation = target else { return }
        target = .conversation(conv)
    }
}
