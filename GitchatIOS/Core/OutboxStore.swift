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
        Self.runSend(for: list[idx])
    }

    /// Run the canonical send pipeline for an already-enqueued pending
    /// message. `Task.detached` so it survives ChatDetailView dismissal.
    /// Single source of truth shared by first-attempt sends and retries.
    static func runSend(for pending: PendingMessage) {
        let convId = pending.conversationID
        let localID = pending.localID
        let body = pending.content
        let replyTo = pending.replyToID
        Task.detached(priority: .userInitiated) {
            do {
                let msg = try await APIClient.shared.sendMessage(
                    conversationId: convId, body: body, replyTo: replyTo
                )
                await MainActor.run {
                    ChatMessageView.seenIds.insert(msg.id)
                    OutboxStore.shared.markDelivered(
                        conversationID: convId, localID: localID
                    )
                }
            } catch {
                await MainActor.run {
                    Haptics.error()
                    ToastCenter.shared.show(.error, "Send failed", error.localizedDescription)
                    OutboxStore.shared.markFailed(
                        conversationID: convId, localID: localID,
                        error: error.localizedDescription
                    )
                }
            }
        }
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
