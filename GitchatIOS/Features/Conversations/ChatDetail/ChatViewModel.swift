import SwiftUI
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var pinnedIds: Set<String> = []
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
    }

    // MARK: - Loading

    func load() async {
        if messages.isEmpty { isLoading = true }
        isSyncing = true
        let started = Date()
        defer {
            isLoading = false
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= 2 {
                isSyncing = false
            } else {
                let remaining = 2 - elapsed
                // Strong-capture self so the deferred reset can't be
                // dropped if SwiftUI rebuilds anything that referenced
                // the view model. The view model lives as long as the
                // chat detail view does.
                let me = self
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    me.isSyncing = false
                }
            }
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
            // Match by client_message_id first (replaces optimistic with stable id)
            if let cmid = srv.client_message_id,
               let idx = existing.firstIndex(where: { $0.client_message_id == cmid }) {
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

        // Collect fetched cmids for the defensive sweep below.
        let fetchedCmids = Set(fetched.compactMap(\.client_message_id))

        // Defensive sweep: remove any remaining local-* placeholder
        //  - whose cmid matches a fetched server message (defensive against the
        //    cmid-match path above missing it — e.g., if both cmid and id matched
        //    different slots and the local-* was not the one replaced)
        //  - OR whose cmid is nil (legacy junk from old builds — see spec §4.3)
        existing.removeAll { msg in
            guard msg.id.hasPrefix("local-") else { return false }
            guard let cmid = msg.client_message_id else { return true }  // legacy junk
            return fetchedCmids.contains(cmid)
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

    func seenByLogins(for message: Message) -> [String] {
        guard conversation.isGroup else { return [] }
        let msgDate = message.created_at ?? ""
        return readCursors.compactMap { login, readAt in
            readAt >= msgDate ? login : nil
        }.sorted()
    }

    func seenCursorLogins(for message: Message, at idx: Int) -> [String] {
        guard conversation.isGroup, !readCursors.isEmpty else { return [] }
        let msgDate = message.created_at ?? ""
        let nextDate: String? = (idx + 1 < messages.count) ? (messages[idx + 1].created_at ?? "") : nil
        return readCursors.compactMap { login, readAt in
            guard readAt >= msgDate else { return nil }
            if let nextDate, readAt >= nextDate { return nil }
            return login
        }.sorted()
    }

    func loadPinned() async {
        do {
            let pins = try await APIClient.shared.pinnedMessages(conversationId: conversation.id)
            self.pinnedIds = Set(pins.map(\.id))
        } catch { }
    }

    // MARK: - Send / edit / delete

    /// Unified send entry point (Task 2.9). Creates an optimistic Message
    /// with id="local-<cmid>" and client_message_id=cmid, appends it to
    /// `messages`, persists the cache, and enqueues a PendingMessage to
    /// the injected OutboxStore so the send pipeline can pick it up.
    ///
    /// Empty content (after trimming) + no attachments is a no-op.
    /// Legacy uploadAndSend / sendEncodedAttachments / uploadImagesAndSend
    /// are preserved until Task 2.13 reroutes their callers and removes them.
    func send(content: String, attachments: [PendingAttachment] = [], replyTo: Message? = nil) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        let cmid = UUID().uuidString
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
                let cmid = UUID().uuidString
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
            is_muted: c.is_muted
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
        } else {
            pinnedIds.insert(msg.id)
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
            if wasPinned {
                pinnedIds.insert(msg.id)
            } else {
                pinnedIds.remove(msg.id)
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

    func uploadAndSendMany(items: [(Data, String, String)], senderLogin: String?) async {
        guard !items.isEmpty else { return }
        var compressed: [(Data, String, String)] = []
        compressed.reserveCapacity(items.count)
        for item in items {
            compressed.append(
                await Self.compressIfImageOffMain(data: item.0, filename: item.1, mimeType: item.2)
            )
        }
        await sendEncodedAttachments(compressed, senderLogin: senderLogin)
    }

    /// UIImage entry point for drop/paste/picker flows. Encodes each image
    /// exactly once, off MainActor, then hands off to the shared upload
    /// pipeline. Avoids the previous pattern where the caller would
    /// `jpegData(...)` on MainActor and `uploadAndSendMany` would then
    /// decode + re-encode via `compressIfImage`.
    func uploadImagesAndSend(images: [UIImage], senderLogin: String?) async {
        guard !images.isEmpty else { return }
        var encoded: [(Data, String, String)] = []
        encoded.reserveCapacity(images.count)
        for (i, img) in images.enumerated() {
            if let tuple = await Self.encodeForUploadOffMain(image: img, filename: "image-\(i).jpg") {
                encoded.append(tuple)
            }
        }
        await sendEncodedAttachments(encoded, senderLogin: senderLogin)
    }

    private func sendEncodedAttachments(
        _ encoded: [(Data, String, String)],
        senderLogin: String?
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
            content: "",
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
                conversationId: conversation.id,
                body: "",
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
                conversationId: conversation.id,
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
