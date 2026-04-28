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

    private let api: APIClientProtocol

    /// Production singleton — uses the real APIClient.
    convenience init() {
        self.init(api: APIClient.shared)
    }

    /// Designated init — injects any APIClientProtocol for testability.
    init(api: APIClientProtocol) {
        self.api = api
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

    /// Adds a new pending message to the queue and immediately kicks off
    /// its send pipeline. Call sites should NOT also call `runSend(for:)`
    /// after enqueueing — that would fire a duplicate send.
    func enqueue(_ msg: PendingMessage) {
        pending[msg.conversationID, default: []].append(msg)
        runSend(for: msg)
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
    func runSend(for msg: PendingMessage) {
        let convId = msg.conversationID
        let prev = sendChain[convId]
        sendChain[convId] = Task { @MainActor [weak self] in
            await prev?.value
            await self?.executeSend(msg)
        }
    }

    // MARK: - FSM send pipeline (Tasks 2.5 + 2.6)

    @MainActor
    private func executeSend(_ pending: PendingMessage) async {
        var p = pending

        // Phase 1 — upload attachments if any are not yet uploaded
        if !p.attachments.isEmpty && p.attachments.contains(where: { $0.uploaded == nil }) {
            p.state = .uploading(progress: 0.0)
            updatePending(p)

            let total = Double(p.attachments.count)
            var done = 0.0
            for i in p.attachments.indices where p.attachments[i].uploaded == nil {
                do {
                    let ref = try await api.uploadAttachment(
                        conversationID: p.conversationID,
                        data: p.attachments[i].sourceData,
                        mimeType: p.attachments[i].mimeType
                    )
                    p.attachments[i].uploaded = ref
                    done += 1
                    p.state = .uploading(progress: done / total)
                    updatePending(p)
                } catch {
                    p.attempts += 1
                    let retriable = isRetriableError(error)
                    p.state = .failed(reason: "Upload failed: \(error)", retriable: retriable)
                    updatePending(p)
                    // Retry scheduling is Task 2.7
                    return
                }
            }
            p.state = .uploaded
            updatePending(p)
        }

        // Phase 2 — send
        p.state = .sending
        updatePending(p)
        do {
            let attachmentDicts: [[String: Any]] = p.attachments.compactMap { att in
                guard let u = att.uploaded else { return nil }
                return [
                    "url": u.url,
                    "storage_path": u.storagePath
                ]
            }
            let serverMsg = try await api.sendMessage(
                conversationID: p.conversationID,
                body: p.content,
                attachments: attachmentDicts,
                replyToID: p.replyToID,
                clientMessageID: p.clientMessageID
            )
            // Re-stamp created_at with the client tap time (matching
            // ms-precision format) so the bubble doesn't jump order
            // relative to still-pending siblings. See original comment
            // in the legacy executeSend for full rationale.
            let stamped = Message(
                id: serverMsg.id,
                client_message_id: serverMsg.client_message_id,
                conversation_id: serverMsg.conversation_id,
                sender: serverMsg.sender,
                sender_avatar: serverMsg.sender_avatar,
                content: serverMsg.content,
                created_at: Self.iso8601.string(from: p.createdAt),
                edited_at: serverMsg.edited_at,
                reactions: serverMsg.reactions,
                attachment_url: serverMsg.attachment_url,
                type: serverMsg.type,
                reply_to_id: serverMsg.reply_to_id,
                reply: serverMsg.reply,
                attachments: serverMsg.attachments,
                unsent_at: serverMsg.unsent_at,
                reactionRows: serverMsg.reactionRows
            )
            p.state = .delivered
            updatePending(p)
            markDelivered(conversationID: p.conversationID, clientMessageID: p.clientMessageID)
            // Hand off to the active view (if any). The handler dedupes via
            // its own atomic `seenIds.insert(...).inserted` against any
            // socket arrival of the same id.
            deliveryHandlers[p.conversationID]?(stamped)
        } catch {
            Haptics.error()
            ToastCenter.shared.show(.error, "Send failed", error.localizedDescription)
            p.attempts += 1
            let retriable = isRetriableError(error)
            p.state = .failed(reason: "\(error)", retriable: retriable)
            updatePending(p)
            // Retry scheduling is Task 2.7
        }
    }

    /// Write `p` back into the pending queue at the slot matching its
    /// `clientMessageID`. No-op if the message has already been removed
    /// (e.g. a concurrent discard).
    private func updatePending(_ p: PendingMessage) {
        guard var list = self.pending[p.conversationID],
              let idx = list.firstIndex(where: { $0.clientMessageID == p.clientMessageID }) else { return }
        list[idx] = p
        self.pending[p.conversationID] = list
    }

    /// Returns true for transient errors that are worth retrying
    /// automatically (Task 2.7 will wire these into the retry scheduler).
    private func isRetriableError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [
                .timedOut, .networkConnectionLost,
                .notConnectedToInternet, .cannotConnectToHost
            ].contains(urlError.code)
        }
        return false
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

    // MARK: - Test helpers

#if DEBUG
    /// Blocks until all pending messages in the store have reached a terminal
    /// state (`.delivered` or `.failed(retriable: false)`), or throws if the
    /// deadline is exceeded. Call from `@MainActor` test bodies.
    @MainActor
    func waitUntilIdle(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let allTerminal = pending.values.allSatisfy {
                $0.allSatisfy { isTerminalState($0.state) }
            }
            if allTerminal { return }
            try await Task.sleep(nanoseconds: 50_000_000) // 50 ms poll
        }
        throw NSError(
            domain: "OutboxStore", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "waitUntilIdle timed out"]
        )
    }

    private func isTerminalState(_ state: PendingMessage.State) -> Bool {
        switch state {
        case .delivered: return true
        case .failed(_, retriable: false): return true
        default: return false
        }
    }
#endif
}
