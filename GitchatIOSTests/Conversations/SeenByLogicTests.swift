import XCTest
@testable import Gitchat

/// Regression tests for the read-tick divergence fixed in May 2026.
///
/// Bug: the long-press menu showed "Seen by N" while the bubble's tick
/// remained single-check, because `seenByLogins` (menu) used 4 sources
/// (cursors + messages-after + reactions + DM fallback) while the tick's
/// predicate (`ChatMessageView.isRead`) and `isReadByOthers` only used
/// cursors + otherReadAt. Commit `dc5cf66` upgraded `seenByLogins` but
/// left the tick's predicate behind.
///
/// Fix: `hasBeenSeenByOthers(message:)` is the single source of truth,
/// derived from `seenByLogins(...).isEmpty == false`. The tick passes
/// through this from `vm` instead of recomputing locally. These tests
/// pin the contract.
@MainActor
final class SeenByLogicTests: XCTestCase {

    private func makeMessage(id: String, sender: String, createdAt: String, conversationID: String) -> Message {
        Message(
            id: id, client_message_id: nil, conversation_id: conversationID,
            sender: sender, sender_avatar: nil, content: id,
            created_at: createdAt, edited_at: nil, reactions: nil,
            attachment_url: nil, type: "user", reply_to_id: nil, reply: nil,
            attachments: nil, unsent_at: nil, reactionRows: nil,
            topicId: nil, forwarded_from_original_author: nil
        )
    }

    /// The motivating bug: B sends a message AFTER A's, but B's readCursor
    /// hasn't updated (e.g. topic-scoped onConversationRead missed). The
    /// long-press menu correctly infers B has seen it; the tick must agree.
    func test_hasBeenSeenByOthers_truesWhen_otherUserSentAfter_evenWithEmptyCursors() {
        let convId = "conv-seen-1"
        let conv = Conversation.testFixture(id: convId)
        let vm = ChatViewModel.testInstance(conversation: conv, outbox: OutboxStore(api: MockAPIClient()))

        let mine = makeMessage(id: "mine", sender: "alice", createdAt: "2026-05-10T23:49:00.000Z", conversationID: convId)
        let theirs = makeMessage(id: "theirs", sender: "norwayiscoming", createdAt: "2026-05-10T23:49:30.000Z", conversationID: convId)

        vm.messages = [mine, theirs]
        // readCursors stays empty — simulates the bug where the cursor update
        // didn't arrive (topic-scoped event missed, push-only delivery, etc.).
        XCTAssertTrue(vm.readCursors.isEmpty)

        XCTAssertFalse(vm.seenByLogins(for: mine).isEmpty,
                       "long-press should see norwayiscoming via messages-after inference")
        XCTAssertTrue(vm.hasBeenSeenByOthers(message: mine),
                      "tick predicate must agree with long-press menu")
        XCTAssertTrue(vm.isReadByOthers(for: mine),
                      "menu's isReadByOthers must also agree")
    }

    /// Inverse: nobody has seen it. Tick stays single-check.
    func test_hasBeenSeenByOthers_falseWhen_noOtherMessagesAfter_andEmptyCursors() {
        let convId = "conv-seen-2"
        let conv = Conversation.testFixture(id: convId)
        let vm = ChatViewModel.testInstance(conversation: conv, outbox: OutboxStore(api: MockAPIClient()))

        let mine = makeMessage(id: "mine", sender: "alice", createdAt: "2026-05-10T23:49:00.000Z", conversationID: convId)
        // Only an earlier message from alice; nothing after.
        let earlier = makeMessage(id: "earlier", sender: "alice", createdAt: "2026-05-10T23:48:00.000Z", conversationID: convId)
        vm.messages = [earlier, mine]

        XCTAssertFalse(vm.hasBeenSeenByOthers(message: mine))
        XCTAssertFalse(vm.isReadByOthers(for: mine))
    }

    /// A later message from the same sender doesn't count (self can't "read"
    /// their own message into existence for tick purposes).
    func test_hasBeenSeenByOthers_falseWhen_onlySelfHasMessagesAfter() {
        let convId = "conv-seen-3"
        let conv = Conversation.testFixture(id: convId)
        let vm = ChatViewModel.testInstance(conversation: conv, outbox: OutboxStore(api: MockAPIClient()))

        let mine1 = makeMessage(id: "mine1", sender: "alice", createdAt: "2026-05-10T23:49:00.000Z", conversationID: convId)
        let mine2 = makeMessage(id: "mine2", sender: "alice", createdAt: "2026-05-10T23:50:00.000Z", conversationID: convId)
        vm.messages = [mine1, mine2]

        XCTAssertFalse(vm.hasBeenSeenByOthers(message: mine1),
                       "messages-after inference must exclude the original sender")
    }

    /// Cursor-driven path still works when cursors do arrive (golden path).
    func test_hasBeenSeenByOthers_truesViaReadCursor() {
        let convId = "conv-seen-4"
        let conv = Conversation.testFixture(id: convId)
        let vm = ChatViewModel.testInstance(conversation: conv, outbox: OutboxStore(api: MockAPIClient()))

        let mine = makeMessage(id: "mine", sender: "alice", createdAt: "2026-05-10T23:49:00.000Z", conversationID: convId)
        vm.messages = [mine]
        vm.readCursors["bob"] = "2026-05-10T23:49:30.000Z"

        XCTAssertTrue(vm.hasBeenSeenByOthers(message: mine))
    }

    /// Reaction inference — if someone reacted, they've obviously seen it.
    func test_hasBeenSeenByOthers_truesViaReaction() {
        let convId = "conv-seen-5"
        let conv = Conversation.testFixture(id: convId)
        let vm = ChatViewModel.testInstance(conversation: conv, outbox: OutboxStore(api: MockAPIClient()))

        let mine = Message(
            id: "mine", client_message_id: nil, conversation_id: convId,
            sender: "alice", sender_avatar: nil, content: "hi",
            created_at: "2026-05-10T23:49:00.000Z",
            edited_at: nil, reactions: nil, attachment_url: nil, type: "user",
            reply_to_id: nil, reply: nil, attachments: nil, unsent_at: nil,
            reactionRows: [RawReactionRow(emoji: "👀", user_login: "bob")],
            topicId: nil, forwarded_from_original_author: nil
        )
        vm.messages = [mine]

        XCTAssertTrue(vm.hasBeenSeenByOthers(message: mine))
    }
}
