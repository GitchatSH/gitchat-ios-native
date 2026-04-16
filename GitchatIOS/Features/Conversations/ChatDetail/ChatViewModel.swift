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

    let conversation: Conversation
    private var draftKey: String { "gitchat.draft.\(conversation.id)" }

    init(conversation: Conversation) {
        self.conversation = conversation
        self.isMuted = conversation.is_muted == true
        if let saved = UserDefaults.standard.string(forKey: "gitchat.draft.\(conversation.id)") {
            self.draft = saved
        }
        if let cached = MessageCache.shared.get(conversation.id) {
            self.messages = cached.messages
            self.nextCursor = cached.nextCursor
            self.otherReadAt = cached.otherReadAt
            if let cursors = cached.readCursors {
                self.readCursors = cursors
            }
            MessageBubble.markSeen(cached.messages.map(\.id))
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
                MessageBubble.markSeen(self.messages.map(\.id))
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
        isLoadingMore = true; defer { isLoadingMore = false }
        do {
            let resp = try await APIClient.shared.getConversationMessages(
                id: conversation.id, cursor: cursor
            )
            let older = resp.messages.reversed()
            let known = Set(messages.map(\.id))
            let deduped = older.filter { !known.contains($0.id) }
            // Older paginated messages should appear immediately, not
            // pop in — mark them seen before they hit the UI.
            MessageBubble.markSeen(deduped.map(\.id))
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

    func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        UserDefaults.standard.removeObject(forKey: draftKey)
        let replyId = replyingTo?.id
        replyingTo = nil
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
                // Optimistic insert so the bubble pops up the instant
                // the user taps send. We keep a local id and swap it for
                // the real one once the server responds.
                let localID = "local-\(UUID().uuidString)"
                let optimistic = Message(
                    id: localID,
                    conversation_id: conversation.id,
                    sender: AuthStore.shared.login ?? "me",
                    sender_avatar: nil,
                    content: body,
                    created_at: ISO8601DateFormatter().string(from: Date()),
                    edited_at: nil,
                    reactions: nil,
                    attachment_url: nil,
                    type: "user",
                    reply_to_id: replyId
                )
                messages.append(optimistic)
                Haptics.impact(.light)
                do {
                    let msg = try await APIClient.shared.sendMessage(
                        conversationId: conversation.id,
                        body: body,
                        replyTo: replyId
                    )
                    // Purge any duplicate the socket may have inserted
                    // between the optimistic append and this response —
                    // the diffable data source crashes on duplicate ids.
                    messages.removeAll { $0.id == msg.id && $0.id != localID }
                    if let idx = messages.firstIndex(where: { $0.id == localID }) {
                        messages[idx] = msg
                    } else {
                        messages.append(msg)
                    }
                } catch {
                    messages.removeAll { $0.id == localID }
                    throw error
                }
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

    func toggleMute() async {
        // Flip optimistically so the menu label updates instantly.
        let wasMuted = isMuted
        isMuted.toggle()
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
        let compressed = items.map { Self.compressIfImage(data: $0.0, filename: $0.1, mimeType: $0.2) }
        var localURLs: [URL] = []
        var localAttachments: [MessageAttachment] = []
        for (data, filename, _) in compressed {
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
                for (i, tuple) in compressed.enumerated() {
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
                var result = Array(repeating: "", count: compressed.count)
                for try await (i, url) in group { result[i] = url }
                return result
            }
            let msg = try await APIClient.shared.sendMessage(
                conversationId: conversation.id,
                body: "",
                attachmentURLs: urls
            )
            if let idx = messages.firstIndex(where: { $0.id == localID }) {
                messages[idx] = msg
            }
            for u in localURLs { try? FileManager.default.removeItem(at: u) }
        } catch {
            messages.removeAll { $0.id == localID }
            ToastCenter.shared.show(.error, "Upload failed", error.localizedDescription)
        }
    }

    func uploadAndSend(data: Data, filename: String, mimeType: String, senderLogin: String?) async {
        let (compressed, usedFilename, usedMime) = Self.compressIfImage(
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
            if let idx = messages.firstIndex(where: { $0.id == localID }) {
                messages[idx] = msg
            } else {
                messages.append(msg)
            }
            try? FileManager.default.removeItem(at: tmpURL)
        } catch {
            self.error = error.localizedDescription
            messages.removeAll { $0.id == localID }
            ToastCenter.shared.show(.error, "Upload failed", error.localizedDescription)
        }
    }

    private static func compressIfImage(
        data: Data, filename: String, mimeType: String
    ) -> (Data, String, String) {
        guard mimeType.hasPrefix("image/"), let image = UIImage(data: data) else {
            return (data, filename, mimeType)
        }
        let maxDim: CGFloat = 1600
        let size = image.size
        let scale = min(1, maxDim / max(size.width, size.height))
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        if let jpeg = resized.jpegData(compressionQuality: 0.75) {
            let base = (filename as NSString).deletingPathExtension
            return (jpeg, "\(base).jpg", "image/jpeg")
        }
        return (data, filename, mimeType)
    }
}
