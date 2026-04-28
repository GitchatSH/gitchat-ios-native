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

    @Published var conversation: Conversation
    private var draftKey: String { "gitchat.draft.\(conversation.id)" }

    private let outbox: OutboxStore

    init(conversation: Conversation, outbox: OutboxStore = .shared) {
        self.outbox = outbox
        self.conversation = conversation
        self.isMuted = conversation.is_muted == true
        if let saved = UserDefaults.standard.string(forKey: "gitchat.draft.\(conversation.id)") {
            self.draft = saved
        }
        if let cached = MessageCache.shared.get(conversation.id) {
            self.messages = cached.messages.filter { !$0.id.hasPrefix("local-") }
            self.nextCursor = cached.nextCursor
            self.otherReadAt = cached.otherReadAt
            if let cursors = cached.readCursors {
                self.readCursors = cursors
            }
            ChatMessageView.markSeen(self.messages.map(\.id))
        }
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
        let pending = OutboxStore.shared.pendingFor(conversation.id)
            .map(OutboxStore.shared.toMessage)
        guard !pending.isEmpty else { return messages }
        // Pending projections share id "local-<cmid>" with optimistic placeholders
        // already in `messages` (from vm.send(content:attachments:)). Skip pending
        // whose id is already present to avoid UIDiffableDataSource duplicate-id crashes.
        let existingIds = Set(messages.map(\.id))
        let unique = pending.filter { !existingIds.contains($0.id) }
        guard !unique.isEmpty else { return messages }
        return (messages + unique).sorted {
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
            let resp = try await APIClient.shared.getConversationMessages(id: conversation.id)
            let fetched = Array(resp.messages.reversed())
            // Merge the fetched newest page into our (possibly larger)
            // cached list instead of overwriting it. This preserves
            // older pages that the user already paged into via
            // scroll-up in a previous session.
            if messages.isEmpty {
                self.messages = fetched
                self.nextCursor = resp.nextCursor
                // Mark the initial page as already-seen so bubbles
                // don't all pop in on first entry — only newly arrived
                // messages should animate in.
                ChatMessageView.markSeen(self.messages.map(\.id))
            } else {
                mergeFromServer(fetched)
                // nextCursor stays as-is — we still know about older
                // pages from the previous session.
            }
            self.otherReadAt = resp.otherReadAt
            print("[SEEN-LOAD] otherReadAt: \(resp.otherReadAt ?? "nil") | readCursors from API: \(resp.readCursors?.map { "\($0.login):\($0.readAt)" } ?? ["nil"])")
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
        isLoadingMore = true; defer { isLoadingMore = false }
        do {
            let resp = try await APIClient.shared.getConversationMessages(
                id: conversation.id, cursor: cursor
            )
            let older = Array(resp.messages.reversed())
            let known = Set(messages.map(\.id))
            let deduped = older.filter { !known.contains($0.id) }
            // Older paginated messages should appear immediately, not
            // pop in — mark them seen before they hit the UI.
            ChatMessageView.markSeen(deduped.map(\.id))
            // mergeFromServer appends, then sorts by created_at ascending,
            // so older-page messages naturally sort to the front.
            mergeFromServer(deduped)
            nextCursor = resp.nextCursor
            persistCache()
        } catch { }
        await loadPinned()
    }

    // MARK: - Merge

    /// Merges a batch of server-fetched messages into `self.messages` with
    /// cmid-aware matching:
    ///
    /// 1. If `client_message_id` matches an existing message's cmid → REPLACE
    ///    (clears the optimistic `local-*` placeholder with the stable server id).
    /// 2. Else if `id` matches existing → REPLACE in-place (handles edits /
    ///    re-fetches).
    /// 3. Else → APPEND (first sighting of this message).
    ///
    /// After incorporating all fetched messages, sweeps and removes:
    /// - Any `local-*` whose cmid matches one of the fetched server messages
    ///   (defensive cleanup of orphans whose cmid-match above didn't fire).
    /// - Any `local-*` with nil cmid (legacy junk from old builds, per spec §4.3).
    ///
    /// Finally, sorts `messages` by `created_at` ascending. This is the single
    /// source of ordering truth; it makes prepend/append semantics for paginated
    /// loads equivalent — older page messages sort to the front naturally because
    /// their `created_at` is earlier.
    func mergeFromServer(_ fetched: [Message]) {
        var existing = self.messages
        for srv in fetched {
            // Match by client_message_id first (replaces optimistic with stable id).
            // Case-insensitive: Swift's UUID().uuidString is UPPERCASE, BE's
            // postgres uuid serialization is lowercase.
            if let cmid = srv.client_message_id,
               let idx = existing.firstIndex(where: { $0.client_message_id?.caseInsensitiveCompare(cmid) == .orderedSame }) {
                existing[idx] = srv
                continue
            }
            // Fall back to id match (handles edited / re-fetched server messages)
            if let idx = existing.firstIndex(where: { $0.id == srv.id }) {
                existing[idx] = srv
                continue
            }
            // First sighting — append
            existing.append(srv)
        }

        // Collect fetched cmids (lowercased) for the defensive sweep below.
        let fetchedCmidsLower = Set(fetched.compactMap { $0.client_message_id?.lowercased() })

        // Defensive sweep: remove any remaining local-* placeholder
        //  - whose cmid matches a fetched server message (defensive against the
        //    cmid-match path above missing it — e.g., if both cmid and id matched
        //    different slots and the local-* was not the one replaced)
        //  - OR whose cmid is nil (legacy junk from old builds — see spec §4.3)
        existing.removeAll { msg in
            guard msg.id.hasPrefix("local-") else { return false }
            guard let cmid = msg.client_message_id else { return true }  // legacy junk
            return fetchedCmidsLower.contains(cmid.lowercased())
        }

        // Sort by created_at ascending (ISO8601 strings are lexicographically
        // ordered). This is stable relative to equal timestamps because Swift's
        // sort is stable since Swift 5.
        existing.sort { ($0.created_at ?? "") < ($1.created_at ?? "") }

        self.messages = existing
    }

    func persistCache() {
        MessageCache.shared.store(conversation.id, entry: MessageCache.Entry(
            messages: self.messages.filter { !$0.id.hasPrefix("local-") },
            nextCursor: self.nextCursor,
            otherReadAt: self.otherReadAt,
            readCursors: self.readCursors.isEmpty ? nil : self.readCursors,
            fetchedAt: Date()
        ))
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoBasic.date(from: s)
    }

    func seenByLogins(for message: Message) -> [String] {
        let sender = message.sender
        guard let msgDateStr = message.created_at,
              let msgDate = Self.parseDate(msgDateStr) else { return [] }

        var logins = Set<String>()

        // 1. Per-user read cursors (from socket real-time events)
        for (login, readAt) in readCursors {
            guard login != sender,
                  let readDate = Self.parseDate(readAt),
                  readDate >= msgDate else { continue }
            logins.insert(login)
        }

        // 2. Users who sent a message AFTER this one = they've been
        //    in the conversation and seen it.
        for msg in messages {
            guard let createdAt = msg.created_at,
                  let d = Self.parseDate(createdAt),
                  d > msgDate,
                  msg.sender != sender else { continue }
            logins.insert(msg.sender)
        }

        // 3. Reaction users — if you reacted, you've seen it
        if let rows = message.reactionRows {
            for row in rows {
                if let login = row.user_login, login != sender {
                    logins.insert(login)
                }
            }
        }

        // 4. DM fallback: otherReadAt
        if logins.isEmpty, !conversation.isGroup,
           let readAt = otherReadAt,
           let readDate = Self.parseDate(readAt),
           readDate >= msgDate,
           let other = conversation.other_user?.login, other != sender {
            logins.insert(other)
        }

        return logins.sorted()
    }

    /// Returns true when we know at least one other user has read past
    /// this message, even if we don't have per-user cursor details.
    func isReadByOthers(for message: Message) -> Bool {
        guard let msgDateStr = message.created_at,
              let msgDate = Self.parseDate(msgDateStr) else { return false }
        // Per-user cursors
        let sender = message.sender
        for (login, readAt) in readCursors {
            if login != sender, let d = Self.parseDate(readAt), d >= msgDate { return true }
        }
        // otherReadAt fallback
        if let readAt = otherReadAt, let d = Self.parseDate(readAt), d >= msgDate { return true }
        return false
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
                let resp = try await APIClient.shared.getConversationMessages(
                    id: conversation.id, cursor: cursor, limit: 50
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
                let resp = try await APIClient.shared.getConversationMessages(
                    id: conversation.id, cursor: c
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

    /// Unified send entry point. Creates an optimistic Message with
    /// id="local-<cmid>" and client_message_id=cmid, appends it to
    /// `messages`, persists the cache, and enqueues a PendingMessage to
    /// the injected OutboxStore so the send pipeline can pick it up.
    ///
    /// Empty content (after trimming) + no attachments is a no-op.
    func send(content: String, attachments: [PendingAttachment] = [], replyTo: Message? = nil) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        // Lowercase to match BE Postgres uuid serialization. Swift's
        // UUID().uuidString is UPPERCASE; BE returns lowercase. Case-sensitive
        // string compare in the delivery handler would otherwise fail to
        // match the optimistic placeholder against the server's echoed cmid.
        let cmid = UUID().uuidString.lowercased()
        let optimistic = Message.optimistic(
            clientMessageID: cmid,
            conversationID: conversation.id,
            sender: AuthStore.shared.login ?? "me",
            content: trimmed,
            attachments: attachments
        )
        messages.append(optimistic)
        persistCache()

        outbox.enqueue(PendingMessage(
            clientMessageID: cmid,
            conversationID: conversation.id,
            content: trimmed,
            replyToID: replyTo?.id,
            attachments: attachments,
            attempts: 0,
            createdAt: Date(),
            state: .enqueued
        ))
    }

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
                // Lowercase: see note in send(content:attachments:replyTo:).
                let cmid = UUID().uuidString.lowercased()
                let pending = PendingMessage(
                    clientMessageID: cmid,
                    conversationID: conversation.id,
                    content: body,
                    replyToID: replyId,
                    attachments: [],
                    attempts: 0,
                    createdAt: Date(),
                    state: .enqueued
                )
                OutboxStore.shared.enqueue(pending)  // enqueue now auto-fires runSend
                Haptics.impact(.light)
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
        conversation = Conversation(
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
            has_reaction: c.has_reaction
        )
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

// MARK: - Test helpers

#if DEBUG
extension ChatViewModel {
    /// Test-only factory. Injects an isolated OutboxStore so tests can
    /// inspect enqueued messages without touching OutboxStore.shared.
    /// Call sites in test code pass a MockAPIClient-backed OutboxStore;
    /// defaults to the real shared store when called from production DEBUG builds.
    static func testInstance(
        conversation: Conversation = .testFixture(),
        outbox: OutboxStore = .shared
    ) -> ChatViewModel {
        ChatViewModel(conversation: conversation, outbox: outbox)
    }
}
#endif
