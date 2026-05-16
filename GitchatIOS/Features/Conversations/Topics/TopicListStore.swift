import Foundation
import Combine

@MainActor
final class TopicListStore: ObservableObject {
    static let shared = TopicListStore(attachToNotificationCenter: true)

    @Published private(set) var topicsByParent: [String: [Topic]] = [:]
    /// Local-only pin state (per parent → set of topic ids), persisted to
    /// UserDefaults. Mirrors the VS Code extension's webview-state pin model:
    /// pin is per-device, never sent to BE, never received via socket.
    @Published private(set) var localPinnedByParent: [String: Set<String>] = [:]
    /// Id of the chat surface (topic id or conversation id) the user is
    /// currently viewing. Used by `applyEvent(.message)` to skip the
    /// unread bump for the active chat — the user is already reading it.
    /// Set by `ChatViewModel` on init/setTarget and cleared on deinit.
    @Published private(set) var activeSurfaceId: String?

    /// Emitted by every successful topic-unread mutation. Subscribers
    /// (e.g. `ConversationsViewModel`) apply the delta to the parent
    /// team's `unreadCount` on the outer Chats list so the badge reflects
    /// topic activity in real time. The delta is the *true* change in
    /// the topic's `unread_count` after clamping — never `-Int.max`.
    let parentUnreadDeltas = PassthroughSubject<ParentUnreadDelta, Never>()

    struct ParentUnreadDelta: Equatable {
        let parentId: String
        let delta: Int
    }

    private var lru: [String] = []                       // recently accessed parentIds (front = newest)
    private let maxParents: Int
    private let defaults: UserDefaults
    private let pinDefaultsKey = "TopicListStore.localPinnedByParent.v1"
    private var topicEventObserver: NSObjectProtocol?

    init(maxParents: Int = 10,
         defaults: UserDefaults = .standard,
         attachToNotificationCenter: Bool = false) {
        self.maxParents = maxParents
        self.defaults = defaults
        loadLocalPins()
        if attachToNotificationCenter {
            // The shared instance owns this subscription so unread badges
            // stay up to date even when no chat view or topic list is on
            // screen (e.g. user is on the outer Chats home tab). Per-view
            // forwarders were the old design and lost events on dismiss.
            topicEventObserver = NotificationCenter.default.addObserver(
                forName: .gitchatTopicEvent, object: nil, queue: .main
            ) { [weak self] note in
                guard let evt = note.object as? TopicSocketEvent else { return }
                Task { @MainActor [weak self] in
                    self?.applyEvent(evt)
                }
            }
        }
    }

    deinit {
        topicEventObserver.map(NotificationCenter.default.removeObserver)
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
        setTopicUnread(topicId: topicId, parentId: parentId) { $0 + delta }
    }

    func clearUnread(topicId: String, parentId: String) {
        setTopicUnread(topicId: topicId, parentId: parentId) { _ in 0 }
    }

    /// Single emission point for topic-unread mutations. Computes the
    /// true delta (`newClamped - old`) after applying the floor-at-zero
    /// clamp, and publishes it to `parentUnreadDeltas`. All callers
    /// (`bumpUnread`, `clearUnread`, and the `.message` realtime path)
    /// route through here so the outer Chats list parent row stays in
    /// sync with topic-level changes.
    private func setTopicUnread(
        topicId: String,
        parentId: String,
        transform: (Int) -> Int
    ) {
        guard var arr = topicsByParent[parentId],
              let idx = arr.firstIndex(where: { $0.id == topicId }) else { return }
        let old = arr[idx].unread_count
        let newClamped = max(0, transform(old))
        let delta = newClamped - old
        guard delta != 0 else { return }
        let t = arr[idx]
        arr[idx] = Topic(
            id: t.id, parent_conversation_id: t.parent_conversation_id,
            name: t.name, icon_emoji: t.icon_emoji, color_token: t.color_token,
            is_general: t.is_general, pin_order: t.pin_order, archived_at: t.archived_at,
            last_message_at: t.last_message_at, last_message_preview: t.last_message_preview,
            last_sender_login: t.last_sender_login, unread_count: newClamped,
            unread_mentions_count: t.unread_mentions_count,
            unread_reactions_count: t.unread_reactions_count,
            created_by: t.created_by, created_at: t.created_at
        )
        topicsByParent[parentId] = sort(arr, parentId: parentId)
        parentUnreadDeltas.send(ParentUnreadDelta(parentId: parentId, delta: delta))
    }

    // MARK: - Active surface

    func setActiveSurface(_ id: String?) {
        activeSurfaceId = id
    }

    /// Clears the active surface ONLY if it currently matches `id`. Guards
    /// against a SwiftUI lifecycle race where ChatViewModel A's deinit
    /// fires after ChatViewModel B has already taken over.
    func clearActiveSurface(_ id: String) {
        if activeSurfaceId == id { activeSurfaceId = nil }
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
        case .message(let parentId, let topicId, let message):
            // Keep the topic row's preview/timestamp/sender in sync with
            // incoming messages so users on the topic-list view see the
            // latest body without waiting for the next `.task` reload.
            //
            // Unread bumping: this is the single source of truth. We bump
            // unless `topicId` is the chat surface the user is currently
            // viewing (which sets itself via `setActiveSurface`). Before,
            // bumping lived in `ChatViewModel.handle(topicEvent:)` which
            // meant badges stopped updating the moment the chat detail
            // was dismissed — see GitchatSH/gitchat-ios-native#150.
            let isActiveSurface = (topicId == activeSurfaceId)
            // Track whether the monotonic guard short-circuited so we
            // don't bump unread for an out-of-order older message.
            var appliedPreviewUpdate = false
            update(topicId: topicId, parentId: parentId) { t in
                if let curAt = t.last_message_at,
                   let msgAt = message.created_at,
                   msgAt < curAt {
                    return
                }
                appliedPreviewUpdate = true
                let preview = message.content.isEmpty ? t.last_message_preview : message.content
                t = Topic(
                    id: t.id, parent_conversation_id: t.parent_conversation_id,
                    name: t.name, icon_emoji: t.icon_emoji, color_token: t.color_token,
                    is_general: t.is_general, pin_order: t.pin_order,
                    archived_at: t.archived_at,
                    last_message_at: message.created_at ?? t.last_message_at,
                    last_message_preview: preview,
                    last_sender_login: message.sender,
                    unread_count: t.unread_count, // unread bumped below via setTopicUnread
                    unread_mentions_count: t.unread_mentions_count,
                    unread_reactions_count: t.unread_reactions_count,
                    created_by: t.created_by, created_at: t.created_at
                )
            }
            if appliedPreviewUpdate && !isActiveSurface {
                setTopicUnread(topicId: topicId, parentId: parentId) { $0 + 1 }
            }
        case .settingsUpdated:
            // Settings events are handled by callers, not the store.
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
