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
    private init() {}

    /// Hoisted to avoid per-call allocation — `toMessage` is invoked
    /// from `ChatViewModel.visibleMessages` on every SwiftUI re-render.
    private static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()

    struct PendingMessage: Identifiable, Equatable {
        let localID: String          // "local-<UUID>"
        let conversationID: String
        let senderLogin: String
        let senderAvatar: String?
        let content: String
        let replyToID: String?
        let createdAt: Date
        var state: State

        enum State: Equatable {
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
    }

    func markDelivered(conversationID: String, localID: String) {
        guard var list = pending[conversationID] else { return }
        list.removeAll { $0.localID == localID }
        if list.isEmpty {
            pending.removeValue(forKey: conversationID)
        } else {
            pending[conversationID] = list
        }
    }

    func markFailed(conversationID: String, localID: String, error: String) {
        guard var list = pending[conversationID],
              let idx = list.firstIndex(where: { $0.localID == localID }) else { return }
        list[idx].state = .failed(message: error)
        pending[conversationID] = list
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

    private func executeSend(for pending: PendingMessage) async {
        let convId = pending.conversationID
        let localID = pending.localID
        do {
            let msg = try await APIClient.shared.sendMessage(
                conversationId: convId,
                body: pending.content,
                replyTo: pending.replyToID
            )
            markDelivered(conversationID: convId, localID: localID)
            // Hand off to the active view (if any). The handler dedupes via
            // its own atomic `seenIds.insert(...).inserted` against any
            // socket arrival of the same id. Do NOT pre-insert into
            // `ChatMessageView.seenIds` here — that would defeat the
            // handler's dedup and the bubble would never render.
            deliveryHandlers[convId]?(msg)
        } catch {
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
