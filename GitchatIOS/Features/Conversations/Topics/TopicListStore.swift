import Foundation
import Combine

@MainActor
final class TopicListStore: ObservableObject {
    static let shared = TopicListStore()

    @Published private(set) var topicsByParent: [String: [Topic]] = [:]
    /// Local-only pin state (per parent → set of topic ids), persisted to
    /// UserDefaults. Mirrors the VS Code extension's webview-state pin model:
    /// pin is per-device, never sent to BE, never received via socket.
    @Published private(set) var localPinnedByParent: [String: Set<String>] = [:]

    private var lru: [String] = []                       // recently accessed parentIds (front = newest)
    private let maxParents: Int
    private let defaults: UserDefaults
    private let pinDefaultsKey = "TopicListStore.localPinnedByParent.v1"

    init(maxParents: Int = 10, defaults: UserDefaults = .standard) {
        self.maxParents = maxParents
        self.defaults = defaults
        loadLocalPins()
    }

    // MARK: - Reads

    func topics(forParent parentId: String) -> [Topic] {
        topicsByParent[parentId] ?? []
    }

    func isLocallyPinned(topicId: String, parentId: String) -> Bool {
        localPinnedByParent[parentId]?.contains(topicId) == true
    }

    // MARK: - Writes

    func setTopics(_ topics: [Topic], forParent parentId: String) {
        topicsByParent[parentId] = sort(topics, parentId: parentId)
        touchLRU(parentId)
    }

    func append(_ topic: Topic, parentId: String) {
        var arr = topicsByParent[parentId] ?? []
        if let idx = arr.firstIndex(where: { $0.id == topic.id }) {
            arr[idx] = topic
        } else {
            arr.append(topic)
        }
        topicsByParent[parentId] = sort(arr, parentId: parentId)
        touchLRU(parentId)
    }

    func update(topicId: String, parentId: String, mutate: (inout Topic) -> Void) {
        guard var arr = topicsByParent[parentId],
              let idx = arr.firstIndex(where: { $0.id == topicId }) else { return }
        mutate(&arr[idx])
        topicsByParent[parentId] = sort(arr, parentId: parentId)
    }

    func togglePin(topicId: String, parentId: String) {
        var set = localPinnedByParent[parentId] ?? []
        if set.contains(topicId) { set.remove(topicId) } else { set.insert(topicId) }
        localPinnedByParent[parentId] = set
        saveLocalPins()
        if let arr = topicsByParent[parentId] {
            topicsByParent[parentId] = sort(arr, parentId: parentId)
        }
    }

    func archive(topicId: String, parentId: String) {
        guard var arr = topicsByParent[parentId] else { return }
        arr.removeAll { $0.id == topicId }
        topicsByParent[parentId] = arr
        // If the archived topic was locally pinned, drop the pin so the
        // user doesn't see a stale pinned id pointing nowhere.
        if var set = localPinnedByParent[parentId], set.remove(topicId) != nil {
            localPinnedByParent[parentId] = set
            saveLocalPins()
        }
    }

    func setPinOrder(topicId: String, parentId: String, order: Int?) {
        update(topicId: topicId, parentId: parentId) { t in
            t = Topic(id: t.id, parent_conversation_id: t.parent_conversation_id,
                      name: t.name, icon_emoji: t.icon_emoji, color_token: t.color_token,
                      is_general: t.is_general, pin_order: order, archived_at: t.archived_at,
                      last_message_at: t.last_message_at, last_message_preview: t.last_message_preview,
                      last_sender_login: t.last_sender_login, unread_count: t.unread_count,
                      unread_mentions_count: t.unread_mentions_count,
                      unread_reactions_count: t.unread_reactions_count,
                      created_by: t.created_by, created_at: t.created_at)
        }
    }

    func bumpUnread(topicId: String, parentId: String, by delta: Int) {
        update(topicId: topicId, parentId: parentId) { t in
            let new = max(0, t.unread_count + delta)
            t = Topic(id: t.id, parent_conversation_id: t.parent_conversation_id,
                      name: t.name, icon_emoji: t.icon_emoji, color_token: t.color_token,
                      is_general: t.is_general, pin_order: t.pin_order, archived_at: t.archived_at,
                      last_message_at: t.last_message_at, last_message_preview: t.last_message_preview,
                      last_sender_login: t.last_sender_login, unread_count: new,
                      unread_mentions_count: t.unread_mentions_count,
                      unread_reactions_count: t.unread_reactions_count,
                      created_by: t.created_by, created_at: t.created_at)
        }
    }

    func clearUnread(topicId: String, parentId: String) {
        bumpUnread(topicId: topicId, parentId: parentId, by: -.max)
    }

    func applyEvent(_ event: TopicSocketEvent) {
        switch event {
        case .created(let parentId, let topic):
            append(topic, parentId: parentId)
        case .updated(let parentId, let topicId, let changes):
            update(topicId: topicId, parentId: parentId) { t in
                t = Topic(id: t.id, parent_conversation_id: t.parent_conversation_id,
                          name: changes.name ?? t.name,
                          icon_emoji: changes.iconEmoji ?? t.icon_emoji,
                          color_token: changes.colorToken ?? t.color_token,
                          is_general: t.is_general, pin_order: t.pin_order,
                          archived_at: t.archived_at, last_message_at: t.last_message_at,
                          last_message_preview: t.last_message_preview,
                          last_sender_login: t.last_sender_login, unread_count: t.unread_count,
                          unread_mentions_count: t.unread_mentions_count,
                          unread_reactions_count: t.unread_reactions_count,
                          created_by: t.created_by, created_at: t.created_at)
            }
        case .archived(let parentId, let topicId):
            archive(topicId: topicId, parentId: parentId)
        case .pinned(let parentId, let topicId, let order):
            setPinOrder(topicId: topicId, parentId: parentId, order: order)
        case .unpinned(let parentId, let topicId):
            setPinOrder(topicId: topicId, parentId: parentId, order: nil)
        case .settingsUpdated, .message:
            // Settings + message events are handled by callers, not the store.
            break
        }
    }

    // MARK: - Private

    /// Sort: General first, then locally-pinned (per-device set), then by
    /// `last_message_at` descending. Mirrors the extension's `sortTopics()`
    /// in `media/webview/topic-list.js`.
    private func sort(_ arr: [Topic], parentId: String) -> [Topic] {
        let pinnedSet = localPinnedByParent[parentId] ?? []
        return arr.sorted { l, r in
            if l.is_general != r.is_general { return l.is_general }
            let lp = pinnedSet.contains(l.id), rp = pinnedSet.contains(r.id)
            if lp != rp { return lp }
            return (l.last_message_at ?? "") > (r.last_message_at ?? "")
        }
    }

    private func loadLocalPins() {
        guard let data = defaults.data(forKey: pinDefaultsKey),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        localPinnedByParent = dict.mapValues { Set($0) }
    }

    private func saveLocalPins() {
        let dict = localPinnedByParent.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: pinDefaultsKey)
        }
    }

    private func touchLRU(_ parentId: String) {
        lru.removeAll { $0 == parentId }
        lru.insert(parentId, at: 0)
        while lru.count > maxParents, let drop = lru.popLast() {
            topicsByParent.removeValue(forKey: drop)
        }
    }
}
