import Foundation

/// Disk-backed cache of the conversation list so cold launches show the
/// previous chat list instantly, then revalidate from the network.
@MainActor
final class ConversationsCache {
    static let shared = ConversationsCache()

    private var memory: [Conversation]?
    private let diskQueue = DispatchQueue(label: "chat.git.ConversationsCache.disk", qos: .utility)

    private init() {}

    private nonisolated var fileURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("conversations.json")
    }

    func get() -> [Conversation]? {
        if let mem = memory { return mem }
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Conversation].self, from: data)
        else { return nil }
        memory = list
        return list
    }

    func store(_ conversations: [Conversation]) {
        memory = conversations
        let url = fileURL
        diskQueue.async {
            if let data = try? JSONEncoder().encode(conversations) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Return a single cached conversation by id, or nil if not present.
    func conversation(id: String) -> Conversation? {
        get()?.first(where: { $0.id == id })
    }

    /// Insert or replace a conversation in the cache (matched by id).
    func upsert(_ conversation: Conversation) {
        var list = get() ?? []
        if let idx = list.firstIndex(where: { $0.id == conversation.id }) {
            list[idx] = conversation
        } else {
            list.insert(conversation, at: 0)
        }
        store(list)
    }

    /// Patch the last-message fields for a single conversation without
    /// touching any other fields (participants, unread_count, etc.).
    /// No-ops silently when the conversation is not in the cache.
    ///
    /// Note: `Conversation` has no `last_sender_login` field (the iOS model
    /// omits it — the BE field is stored only on `Topic`). Pass `nil` to
    /// leave `last_message_at` / `last_message_preview` unchanged.
    @MainActor
    func patchLastMessage(conversationId: String,
                          text: String?,
                          at: String?) {
        guard let existing = conversation(id: conversationId) else { return }
        let patched = Conversation(
            id: existing.id,
            type: existing.type,
            is_group: existing.is_group,
            group_name: existing.group_name,
            group_avatar_url: existing.group_avatar_url,
            repo_full_name: existing.repo_full_name,
            participants: existing.participants,
            other_user: existing.other_user,
            last_message: existing.last_message,
            last_message_preview: text ?? existing.last_message_preview,
            last_message_text: text ?? existing.last_message_text,
            last_message_at: at ?? existing.last_message_at,
            unread_count: existing.unread_count,
            pinned: existing.pinned,
            pinned_at: existing.pinned_at,
            is_request: existing.is_request,
            updated_at: at ?? existing.updated_at,
            is_muted: existing.is_muted,
            has_mention: existing.has_mention,
            has_reaction: existing.has_reaction,
            topics_enabled: existing.topics_enabled,
            has_topics: existing.has_topics,
            topic_chips: existing.topic_chips
        )
        upsert(patched)
    }
}
