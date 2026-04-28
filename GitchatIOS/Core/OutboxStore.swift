import Foundation
import Combine

/// Lifetime-independent store of in-flight ("pending") sends, keyed by
/// conversation id. Survives ChatDetailView dismissal so a re-entered
/// conversation continues to show its pending bubbles.
///
/// Pending messages live ONLY here. Server-confirmed messages live ONLY
/// in `ChatViewModel.messages`. They're merged at render time by
/// `ChatViewModel.visibleMessages`.
///
/// Mutations are @MainActor; consumers observing the store re-render on
/// every change via the @Published `pending` dict.
@MainActor
final class OutboxStore: ObservableObject {
    static let shared = OutboxStore()
    private init() { loadFromDisk() }

    // MARK: - Disk persistence

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("outbox-pending.json")
    }()

    private func saveToDisk() {
        // Only persist failed messages — sending ones will be
        // re-attempted on next launch anyway.
        var failed: [String: [PendingMessage]] = [:]
        for (convId, list) in pending {
            let failedOnly = list.filter { if case .failed = $0.state { return true }; return false }
            if !failedOnly.isEmpty { failed[convId] = failedOnly }
        }
        do {
            let data = try JSONEncoder().encode(failed)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            // Best-effort persist — log but don't crash.
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode([String: [PendingMessage]].self, from: data) else { return }
        pending = stored
    }

    /// Hoisted to avoid per-call allocation — `toMessage` is invoked
    /// from `ChatViewModel.visibleMessages` on every SwiftUI re-render.
    /// Includes fractional seconds so the `created_at` strings sort
    /// lex-consistently with the BE's millisecond-precision timestamps —
    /// otherwise a pending bubble (sec precision, "...:18Z") and a server
    /// bubble (ms precision, "...:18.636Z") at the same second would
    /// compare in the wrong order ('.' < 'Z' in ASCII).
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    struct PendingMessage: Identifiable, Equatable, Codable {
        let localID: String          // "local-<UUID>"
        let conversationID: String
        let senderLogin: String
        let senderAvatar: String?
        let content: String
        let replyToID: String?
        let createdAt: Date
        var state: State
        /// Non-nil when this message targets a topic rather than a plain
        /// conversation. Both fields are Optional so old persisted outbox
        /// items (which lack these keys) decode cleanly via Codable — the
        /// decoder sets them to nil automatically.
        let topicID: String?
        let parentConversationID: String?       // present iff topicID is non-nil

        enum State: Equatable, Codable {
            case sending
            case failed(message: String)
        }

        var id: String { localID }
    }

    /// Key: conversationID. Value: pending messages in enqueue order.
    @Published private(set) var pending: [String: [PendingMessage]] = [:]

    /// Per-conversation FIFO send queue. Each new send to a conversation
    /// awaits the previous one — so the BE INSERT order matches the user's
    /// tap order. Cross-conversation sends remain parallel.
    private var sendChain: [String: Task<Void, Never>] = [:]

    /// Per-conversation delivery handlers registered by an active
    /// `ChatDetailView`. When a send completes, the handler is invoked
    /// with the server-confirmed Message so the view's `vm.messages` can
    /// pick it up directly — no dependency on the WebSocket. If no view
    /// is mounted (user backed out), no handler is registered → no-op,
    /// and the next `vm.load()` on re-entry will fetch the message.
    private var deliveryHandlers: [String: (Message) -> Void] = [:]

    // MARK: - Mutators

    func enqueue(_ msg: PendingMessage) {
        pending[msg.conversationID, default: []].append(msg)
        saveToDisk()
    }

    func markDelivered(conversationID: String, localID: String) {
        guard var list = pending[conversationID] else { return }
        list.removeAll { $0.localID == localID }
        if list.isEmpty {
            pending.removeValue(forKey: conversationID)
        } else {
            pending[conversationID] = list
        }
        saveToDisk()
    }

    func markFailed(conversationID: String, localID: String, error: String) {
        guard var list = pending[conversationID],
              let idx = list.firstIndex(where: { $0.localID == localID }) else { return }
        list[idx].state = .failed(message: error)
        pending[conversationID] = list
        saveToDisk()
    }

    /// User-initiated discard of a `.failed` pending. Same wire effect as
    /// `markDelivered` (entry leaves the store), but the distinct name lets
    /// call sites express intent ("the user threw it away" vs "the server
    /// confirmed it").
    func discard(conversationID: String, localID: String) {
        markDelivered(conversationID: conversationID, localID: localID)
    }

    /// Flip a failed pending back to .sending and re-fire the send
    /// pipeline.
    func retry(_ pendingMsg: PendingMessage) {
        guard var list = pending[pendingMsg.conversationID],
              let idx = list.firstIndex(where: { $0.localID == pendingMsg.localID }) else { return }
        list[idx].state = .sending
        pending[pendingMsg.conversationID] = list
        runSend(for: list[idx])
    }

    /// Run the canonical send pipeline for an already-enqueued pending
    /// message. The send is appended to the conversation's FIFO queue so
    /// rapid taps result in serialized HTTP requests — preserving order
    /// at the BE. The chained Task survives `ChatDetailView` dismissal
    /// because it's owned by `OutboxStore.shared`, not by the view.
    /// Shared by first-attempt sends and retries.
    func runSend(for pending: PendingMessage) {
        let convId = pending.conversationID
        let prev = sendChain[convId]
        sendChain[convId] = Task { @MainActor [weak self] in
            await prev?.value
            await self?.executeSend(for: pending)
        }
    }

    /// Compute the send endpoint for a pending message. Topic sends use the
    /// parent-prefixed path; plain-conversation sends use the legacy id-based path.
    private func sendEndpoint(for msg: PendingMessage) -> String? {
        if let topicID = msg.topicID, let parentID = msg.parentConversationID {
            return TopicEndpoints.sendMessage(parentId: parentID, topicId: topicID)
        }
        return nil          // caller falls back to conversationId-based API
    }

    private func executeSend(for pending: PendingMessage) async {
        let convId = pending.conversationID
        let localID = pending.localID
        do {
            let msg: Message
            if let path = sendEndpoint(for: pending) {
                msg = try await APIClient.shared.sendMessage(
                    at: path,
                    body: pending.content,
                    replyTo: pending.replyToID
                )
            } else {
                msg = try await APIClient.shared.sendMessage(
                    conversationId: convId,
                    body: pending.content,
                    replyTo: pending.replyToID
                )
            }
            // Keep the bubble in its typed-order position across the
            // pending→server transition: re-stamp `created_at` with the
            // pending's client tap time (matching ms-precision format).
            // BE INSERT time can be ~hundreds of ms later than the user's
            // tap, which would otherwise cause the bubble to "jump" out of
            // tap-order when it's sorted alongside still-pending siblings.
            // On next vm.load() the BE time replaces this — but by then
            // all sends in the burst have completed, so chain order = BE
            // order = tap order; no visible re-sort.
            let stamped = Message(
                id: msg.id,
                conversation_id: msg.conversation_id,
                sender: msg.sender,
                sender_avatar: msg.sender_avatar,
                content: msg.content,
                created_at: Self.iso8601.string(from: pending.createdAt),
                edited_at: msg.edited_at,
                reactions: msg.reactions,
                attachment_url: msg.attachment_url,
                type: msg.type,
                reply_to_id: msg.reply_to_id,
                reply: msg.reply,
                attachments: msg.attachments,
                unsent_at: msg.unsent_at,
                reactionRows: msg.reactionRows
            )
            markDelivered(conversationID: convId, localID: localID)
            // Hand off to the active view (if any). The handler dedupes via
            // its own atomic `seenIds.insert(...).inserted` against any
            // socket arrival of the same id. Do NOT pre-insert into
            // `ChatMessageView.seenIds` here — that would defeat the
            // handler's dedup and the bubble would never render.
            deliveryHandlers[convId]?(stamped)
        } catch {
            // 410 Gone + TOPIC_ARCHIVED: topic was archived before the send
            // could flush. Drop the item silently (retrying forever would be
            // pointless) and surface a descriptive toast.
            if case APIError.http(410, let body) = error,
               body?.contains("TOPIC_ARCHIVED") == true {
                ToastCenter.shared.show(.error, "Topic was archived", "Message not sent")
                markDelivered(conversationID: convId, localID: localID)
                return
            }
            Haptics.error()
            ToastCenter.shared.show(.error, "Send failed", error.localizedDescription)
            markFailed(
                conversationID: convId, localID: localID,
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Delivery handler registration

    /// Called by `ChatDetailView` when it appears. The handler receives
    /// the server-confirmed Message for any send to this conversation
    /// that lands while the view is mounted, so the view can append it to
    /// its vm.messages directly without waiting for a socket event.
    ///
    /// One handler per conversation; calling again replaces the previous.
    func registerDeliveryHandler(conversationID: String, _ handler: @escaping (Message) -> Void) {
        deliveryHandlers[conversationID] = handler
    }

    /// Called by `ChatDetailView` on disappear. Drops the handler so a
    /// later delivery for this conversation falls back to the no-op path
    /// (next `vm.load()` will pick the message up from the BE).
    func unregisterDeliveryHandler(conversationID: String) {
        deliveryHandlers.removeValue(forKey: conversationID)
    }

    // MARK: - Reads

    func pendingFor(_ conversationID: String) -> [PendingMessage] {
        pending[conversationID] ?? []
    }

    func pending(conversationID: String, localID: String) -> PendingMessage? {
        pending[conversationID]?.first(where: { $0.localID == localID })
    }

    /// Adapt a PendingMessage to the existing Message shape so the same
    /// rendering code can render both. id keeps the "local-" prefix so
    /// downstream rendering can still detect "this is a pending bubble".
    func toMessage(_ p: PendingMessage) -> Message {
        Message(
            id: p.localID,
            conversation_id: p.conversationID,
            sender: p.senderLogin,
            sender_avatar: p.senderAvatar,
            content: p.content,
            created_at: Self.iso8601.string(from: p.createdAt),
            edited_at: nil,
            reactions: nil,
            attachment_url: nil,
            type: "user",
            reply_to_id: p.replyToID
        )
    }
}
