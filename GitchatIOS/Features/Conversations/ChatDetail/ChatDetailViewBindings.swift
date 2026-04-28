import Foundation

/// Testable factories for the two message-arrival closures that `ChatDetailView`
/// wires up during `onAppear`.
///
/// Both handlers share the same matching strategy:
///   1. If the incoming `Message` carries a `client_message_id` that matches an
///      optimistic placeholder already in `vm.messages`, **replace** the placeholder
///      in-place. This is the canonical outbound-success path.
///   2. Otherwise fall back to `seenIds` dedup (insert-returns-false means
///      duplicate; inbound messages from other senders have no local placeholder).
///
/// The socket handler additionally calls `markRead` for non-self messages.
/// The outbox delivery handler skips `markRead` because delivery is always for
/// outbound (self-authored) messages.
@MainActor
enum ChatDetailViewBindings {

    /// Factory for `socket.onMessageSent`.
    ///
    /// Matches optimistic ↔ server message by `client_message_id` first; falls
    /// back to `seenIds` dedup for messages without a cmid (inbound from other
    /// senders, retry replays, legacy extension-sent messages).
    static func makeSocketMessageSentHandler(vm: ChatViewModel) -> (Message) -> Void {
        return { msg in
            guard msg.conversation_id == vm.conversation.id else { return }
            print("[CMID-DEBUG] ws-onMessageSent: id=\(msg.id) cmid=\(msg.client_message_id ?? "nil") | vm.messages.cmids=\(vm.messages.compactMap(\.client_message_id))")

            // 1. Outbound match by cmid — replace optimistic placeholder in-place.
            if let cmid = msg.client_message_id,
               let idx = vm.messages.firstIndex(where: { $0.client_message_id == cmid }) {
                print("[CMID-DEBUG] ws-onMessageSent: REPLACE idx=\(idx)")
                vm.messages[idx] = msg
                ChatMessageView.seenIds.insert(msg.id)
                vm.persistCache()
                return
            }

            // 2. Inbound dedup by server id.
            guard ChatMessageView.seenIds.insert(msg.id).inserted else { return }
            print("[CMID-DEBUG] ws-onMessageSent: APPEND (no cmid match)")
            vm.messages.append(msg)
            vm.persistCache()

            // 3. markRead for messages from other senders.
            if msg.sender != AuthStore.shared.login {
                Task { try? await APIClient.shared.markRead(conversationId: vm.conversation.id) }
            }
        }
    }

    /// Factory for the `OutboxStore` delivery handler.
    ///
    /// Same matching rules as `makeSocketMessageSentHandler`, minus the
    /// `markRead` branch — delivery is always for outbound (self-authored)
    /// messages, so `markRead` is never needed here.
    static func makeOutboxDeliveryHandler(vm: ChatViewModel) -> (Message) -> Void {
        return { msg in
            print("[CMID-DEBUG] outbox-delivery: id=\(msg.id) cmid=\(msg.client_message_id ?? "nil") | vm.messages.cmids=\(vm.messages.compactMap(\.client_message_id))")
            // 1. Outbound match by cmid — replace optimistic placeholder in-place.
            if let cmid = msg.client_message_id,
               let idx = vm.messages.firstIndex(where: { $0.client_message_id == cmid }) {
                print("[CMID-DEBUG] outbox-delivery: REPLACE idx=\(idx)")
                vm.messages[idx] = msg
                ChatMessageView.seenIds.insert(msg.id)
                vm.persistCache()
                return
            }

            // 2. Inbound dedup by server id.
            guard ChatMessageView.seenIds.insert(msg.id).inserted else { return }
            print("[CMID-DEBUG] outbox-delivery: APPEND (no cmid match)")
            vm.messages.append(msg)
            vm.persistCache()
        }
    }
}
