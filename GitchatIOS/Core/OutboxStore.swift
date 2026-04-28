import Foundation
import Combine

// MARK: - Attachment types (Task 2.3)

struct PendingAttachment: Codable, Equatable {
    let clientAttachmentID: String
    var sourceData: Data
    let mimeType: String
    let width: Int?
    let height: Int?
    let blurhash: String?
    var uploaded: UploadedRef?
}

struct UploadedRef: Codable, Equatable {
    let url: String
    let storagePath: String
    let sizeBytes: Int
}

// MARK: - PendingMessage (Task 2.4)

struct PendingMessage: Codable, Equatable {
    let clientMessageID: String
    let conversationID: String
    var content: String
    var replyToID: String?
    var attachments: [PendingAttachment]
    var attempts: Int
    var createdAt: Date
    var state: State

    static func optimisticID(for clientMessageID: String) -> String {
        "local-\(clientMessageID)"
    }

    /// Lifecycle states for the outbox FSM.
    ///
    /// - enqueued:            Queued but send task not yet started.
    /// - uploading(progress): Attachment upload(s) in flight.
    /// - uploaded:            All attachments uploaded; HTTP send not yet fired.
    /// - sending:             HTTP send request in flight.
    /// - delivered:           Server confirmed; entry is about to be removed.
    /// - failed(reason, retriable): Terminal error; user can retry or discard.
    enum State: Equatable, Codable {
        case enqueued
        case uploading(progress: Double)
        case uploaded
        case sending
        case delivered
        case failed(reason: String, retriable: Bool)
    }
}

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

    func markDelivered(conversationID: String, clientMessageID: String) {
        guard var list = pending[conversationID] else { return }
        list.removeAll { $0.clientMessageID == clientMessageID }
        if list.isEmpty {
            pending.removeValue(forKey: conversationID)
        } else {
            pending[conversationID] = list
        }
    }

    func markFailed(conversationID: String, clientMessageID: String, error: String) {
        guard var list = pending[conversationID],
              let idx = list.firstIndex(where: { $0.clientMessageID == clientMessageID }) else { return }
        list[idx].state = .failed(reason: error, retriable: true)
        pending[conversationID] = list
    }

    /// User-initiated discard of a `.failed` pending (keyed by optimistic ID,
    /// e.g. "local-<cmid>"). Same wire effect as `markDelivered` (entry
    /// leaves the store), but the distinct name lets call sites express intent.
    func discard(conversationID: String, optimisticID: String) {
        guard var list = pending[conversationID] else { return }
        list.removeAll { PendingMessage.optimisticID(for: $0.clientMessageID) == optimisticID }
        if list.isEmpty {
            pending.removeValue(forKey: conversationID)
        } else {
            pending[conversationID] = list
        }
    }

    /// Flip a failed pending back to .sending and re-fire the send
    /// pipeline.
    func retry(_ pendingMsg: PendingMessage) {
        guard var list = pending[pendingMsg.conversationID],
              let idx = list.firstIndex(where: { $0.clientMessageID == pendingMsg.clientMessageID }) else { return }
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
        let clientMessageID = pending.clientMessageID
        do {
            let msg = try await APIClient.shared.sendMessage(
                conversationId: convId,
                body: pending.content,
                replyTo: pending.replyToID
            )
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
            markDelivered(conversationID: convId, clientMessageID: clientMessageID)
            // Hand off to the active view (if any). The handler dedupes via
            // its own atomic `seenIds.insert(...).inserted` against any
            // socket arrival of the same id. Do NOT pre-insert into
            // `ChatMessageView.seenIds` here — that would defeat the
            // handler's dedup and the bubble would never render.
            deliveryHandlers[convId]?(stamped)
        } catch {
            Haptics.error()
            ToastCenter.shared.show(.error, "Send failed", error.localizedDescription)
            markFailed(
                conversationID: convId, clientMessageID: clientMessageID,
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

    func pending(conversationID: String, optimisticID: String) -> PendingMessage? {
        pending[conversationID]?.first(where: { PendingMessage.optimisticID(for: $0.clientMessageID) == optimisticID })
    }

    /// Adapt a PendingMessage to the existing Message shape so the same
    /// rendering code can render both. id keeps the "local-" prefix so
    /// downstream rendering can still detect "this is a pending bubble".
    /// Pending messages are always the current user's outbound sends, so
    /// sender identity is read from AuthStore.
    func toMessage(_ p: PendingMessage) -> Message {
        Message(
            id: PendingMessage.optimisticID(for: p.clientMessageID),
            conversation_id: p.conversationID,
            sender: AuthStore.shared.login ?? "me",
            sender_avatar: nil,
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
