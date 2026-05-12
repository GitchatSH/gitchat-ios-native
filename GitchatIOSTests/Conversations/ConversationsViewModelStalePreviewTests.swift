import XCTest
@testable import Gitchat

/// Regression tests for the chat-list stale-preview bug: receiver's
/// conversation list got stuck on an older message body (e.g. "5") while
/// the message-create UPDATE race window on BE was open and an
/// out-of-order socket event applied an older message. BE fix lives in
/// gitchat-webapp/backend/src/modules/messages/services/messages.service.ts:1516.
@MainActor
final class ConversationsViewModelStalePreviewTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        MessageCache.shared.clearForTesting()
    }

    // MARK: - applyIncomingMessage monotonic guard

    func test_applyIncomingMessage_skipsMessageOlderThanCurrentRow() {
        let vm = ConversationsViewModel()
        vm.conversations = [makeConversation(
            id: "c1",
            lastText: "6",
            lastAt: "2026-05-12T10:35:00.500Z"
        )]

        let older = makeMessage(
            content: "5",
            conversationID: "c1",
            createdAt: "2026-05-12T10:35:00.100Z"
        )
        vm.applyIncomingMessage(older)

        XCTAssertEqual(vm.conversations.first?.last_message_text, "6")
        XCTAssertEqual(vm.conversations.first?.last_message_at,
                       "2026-05-12T10:35:00.500Z")
    }

    func test_applyIncomingMessage_appliesMessageNewerThanCurrentRow() {
        let vm = ConversationsViewModel()
        vm.conversations = [makeConversation(
            id: "c1",
            lastText: "5",
            lastAt: "2026-05-12T10:35:00.100Z"
        )]

        let newer = makeMessage(
            content: "6",
            conversationID: "c1",
            createdAt: "2026-05-12T10:35:00.500Z"
        )
        vm.applyIncomingMessage(newer)

        XCTAssertEqual(vm.conversations.first?.last_message_text, "6")
        XCTAssertEqual(vm.conversations.first?.last_message_at,
                       "2026-05-12T10:35:00.500Z")
    }

    func test_applyIncomingMessage_appliesWhenRowHasNoTimestamp() {
        let vm = ConversationsViewModel()
        vm.conversations = [makeConversation(
            id: "c1",
            lastText: nil,
            lastAt: nil
        )]

        let msg = makeMessage(
            content: "hi",
            conversationID: "c1",
            createdAt: "2026-05-12T10:35:00.100Z"
        )
        vm.applyIncomingMessage(msg)

        XCTAssertEqual(vm.conversations.first?.last_message_text, "hi")
    }

    func test_applyIncomingMessage_appliesWhenMessageHasNoTimestamp() {
        // Defensive: a Message without created_at (legacy/extension client)
        // should still update the row rather than being silently skipped.
        let vm = ConversationsViewModel()
        vm.conversations = [makeConversation(
            id: "c1",
            lastText: "5",
            lastAt: "2026-05-12T10:35:00.100Z"
        )]

        let msg = makeMessage(
            content: "6",
            conversationID: "c1",
            createdAt: nil
        )
        vm.applyIncomingMessage(msg)

        XCTAssertEqual(vm.conversations.first?.last_message_text, "6")
    }

    // MARK: - MessageCache sync (real root cause of the original bug)

    func test_applyIncomingMessage_upsertsIntoMessageCache_whenEntryExists() {
        // Repro of the actual production bug: chat-list cell's
        // `formattedPreview` reads `MessageCache.last(user)` BEFORE
        // falling back to `conversation.last_message`. So a fresh
        // socket `message:sent` that only updates the conversation row
        // leaves the cell rendering the previous message body.
        let convID = "conv-cache-sync-\(UUID().uuidString)"
        let existing = Message.testFixture(id: "srv-3", conversationID: convID, content: "3")
        MessageCache.shared.store(convID, entry: MessageCache.Entry(
            messages: [existing], nextCursor: nil, otherReadAt: nil,
            readCursors: nil, fetchedAt: Date()
        ))

        let vm = ConversationsViewModel()
        vm.conversations = [makeConversation(
            id: convID,
            lastText: "3",
            lastAt: "2026-05-12T10:35:00.100Z"
        )]

        let newer = makeMessage(
            content: "4",
            conversationID: convID,
            createdAt: "2026-05-12T10:35:00.500Z"
        )
        vm.applyIncomingMessage(newer)

        let entry = MessageCache.shared.get(convID)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.messages.last?.content, "4",
                       "cache's last message should be the just-applied one")
        XCTAssertEqual(entry?.messages.count, 2)
    }

    func test_applyIncomingMessage_doesNotCreateCacheEntry_whenNoneExists() {
        // upsertDelivered is documented as a no-op when there's no entry.
        // applyIncomingMessage shouldn't change that contract — populating
        // the cache from scratch is `prefetch`'s job.
        let convID = "conv-no-cache-\(UUID().uuidString)"
        let vm = ConversationsViewModel()
        vm.conversations = [makeConversation(
            id: convID, lastText: nil, lastAt: nil
        )]

        let msg = makeMessage(
            content: "hi", conversationID: convID,
            createdAt: "2026-05-12T10:35:00Z"
        )
        vm.applyIncomingMessage(msg)

        XCTAssertNil(MessageCache.shared.get(convID))
    }

    func test_applyIncomingMessage_doesNotUpsertCache_whenMessageIsOlder() {
        // Monotonic guard already returns early — the cache upsert sits
        // after it, so an older message must not slip into the cache and
        // become the cell's "last user message" via the .last accessor.
        let convID = "conv-cache-skip-older-\(UUID().uuidString)"
        let existing4 = Message.testFixture(id: "srv-4", conversationID: convID, content: "4")
        MessageCache.shared.store(convID, entry: MessageCache.Entry(
            messages: [existing4], nextCursor: nil, otherReadAt: nil,
            readCursors: nil, fetchedAt: Date()
        ))

        let vm = ConversationsViewModel()
        vm.conversations = [makeConversation(
            id: convID,
            lastText: "4",
            lastAt: "2026-05-12T10:35:00.500Z"
        )]

        let older = makeMessage(
            content: "3", conversationID: convID,
            createdAt: "2026-05-12T10:35:00.100Z"
        )
        vm.applyIncomingMessage(older)

        let entry = MessageCache.shared.get(convID)
        XCTAssertEqual(entry?.messages.map(\.content), ["4"],
                       "older message must not be appended after newer cache state")
    }

    // MARK: - renderableLastMessage merge (chat-list cell render source)

    func test_renderableLastMessage_prefersBE_whenCacheAndBEDisagreeOnId() {
        // Bug repro: cache has msg "4" (one behind), BE refetch returned
        // msg "5" as the conversation's last_message. Cell render must
        // pick BE's "5", not cache's "4". BE-hydrated last_message has
        // no `created_at`, so the merge is by id-disagreement.
        let cachedMsg4 = makeMessage(content: "4", conversationID: "c1", createdAt: nil)
        let beMsg5 = makeMessage(content: "5", conversationID: "c1", createdAt: nil)
        var c = makeConversation(id: "c1", lastText: "5", lastAt: "2026-05-12T10:35:00Z")
        c = c.withLastMessage(beMsg5)

        let picked = c.renderableLastMessage(cached: cachedMsg4)

        XCTAssertEqual(picked?.content, "5")
        XCTAssertEqual(picked?.id, beMsg5.id)
    }

    func test_renderableLastMessage_prefersCache_whenIdsMatch() {
        // Same message id on both sides → use cache so we keep richer
        // per-message state (unsent_at, edited_at, attachments) that BE's
        // hydrated `last_message` payload doesn't carry.
        let sharedId = "msg-shared-id"
        let cachedMsg = Message(
            id: sharedId, client_message_id: nil, conversation_id: "c1",
            sender: "alice", sender_avatar: nil, content: "hello (with attachments)",
            created_at: nil, edited_at: "2026-05-12T10:00:00Z", reactions: nil,
            attachment_url: nil, type: "user", reply_to_id: nil, reply: nil,
            attachments: nil, unsent_at: nil, reactionRows: nil, topicId: nil,
            forwarded_from_original_author: nil
        )
        let beMsg = Message(
            id: sharedId, client_message_id: nil, conversation_id: "c1",
            sender: "alice", sender_avatar: nil, content: "hello", created_at: nil,
            edited_at: nil, reactions: nil, attachment_url: nil, type: "user",
            reply_to_id: nil, reply: nil, attachments: nil, unsent_at: nil,
            reactionRows: nil, topicId: nil, forwarded_from_original_author: nil
        )
        var c = makeConversation(id: "c1", lastText: "hello", lastAt: nil)
        c = c.withLastMessage(beMsg)

        let picked = c.renderableLastMessage(cached: cachedMsg)

        XCTAssertEqual(picked?.id, sharedId)
        XCTAssertEqual(picked?.edited_at, "2026-05-12T10:00:00Z",
                       "should be the cache copy (carrying edited_at) since ids match")
    }

    func test_renderableLastMessage_fallsBackToCache_whenBELackedHydration() {
        let cachedMsg = makeMessage(content: "only-cache", conversationID: "c1", createdAt: nil)
        let c = makeConversation(id: "c1", lastText: nil, lastAt: nil)
        XCTAssertNil(c.last_message)

        let picked = c.renderableLastMessage(cached: cachedMsg)

        XCTAssertEqual(picked?.content, "only-cache")
    }

    func test_renderableLastMessage_fallsBackToBE_whenCacheIsNil() {
        let beMsg = makeMessage(content: "only-BE", conversationID: "c1", createdAt: nil)
        var c = makeConversation(id: "c1", lastText: "only-BE", lastAt: nil)
        c = c.withLastMessage(beMsg)

        let picked = c.renderableLastMessage(cached: nil)

        XCTAssertEqual(picked?.content, "only-BE")
    }

    func test_renderableLastMessage_returnsNil_whenBothNil() {
        let c = makeConversation(id: "c1", lastText: nil, lastAt: nil)
        XCTAssertNil(c.renderableLastMessage(cached: nil))
    }

    // MARK: - withLatestMessageFrom helper

    func test_withLatestMessageFrom_takesMessageFieldsFromSourceKeepsRest() {
        let base = makeConversation(
            id: "c1",
            lastText: "old",
            lastAt: "2026-05-12T10:00:00Z",
            unreadCount: 7,
            isMuted: true
        )
        let fresher = makeConversation(
            id: "c1",
            lastText: "new",
            lastAt: "2026-05-12T10:30:00Z",
            unreadCount: 99,         // should NOT carry over
            isMuted: false           // should NOT carry over
        )

        let merged = base.withLatestMessageFrom(fresher)

        XCTAssertEqual(merged.last_message_text, "new")
        XCTAssertEqual(merged.last_message_at, "2026-05-12T10:30:00Z")
        // Non-message fields keep base's values.
        XCTAssertEqual(merged.unread_count, 7)
        XCTAssertEqual(merged.is_muted, true)
        XCTAssertEqual(merged.id, "c1")
    }

    // MARK: - Helpers

    private func makeConversation(
        id: String,
        lastText: String?,
        lastAt: String?,
        unreadCount: Int? = 0,
        isMuted: Bool? = false
    ) -> Conversation {
        Conversation(
            id: id, type: "dm", is_group: false,
            group_name: nil, group_avatar_url: nil, repo_full_name: nil,
            participants: [], other_user: nil,
            last_message: nil,
            last_message_preview: lastText,
            last_message_text: lastText,
            last_message_at: lastAt,
            unread_count: unreadCount,
            pinned: false, pinned_at: nil, is_request: false, updated_at: nil,
            is_muted: isMuted, has_mention: false, has_reaction: false,
            topics_enabled: nil, has_topics: nil, topic_chips: nil
        )
    }

    private func makeMessage(
        content: String,
        conversationID: String,
        createdAt: String?
    ) -> Message {
        Message(
            id: UUID().uuidString,
            client_message_id: nil,
            conversation_id: conversationID,
            sender: "alice",
            sender_avatar: nil,
            content: content,
            created_at: createdAt,
            edited_at: nil,
            reactions: nil,
            attachment_url: nil,
            type: "user",
            reply_to_id: nil,
            reply: nil,
            attachments: nil,
            unsent_at: nil,
            reactionRows: nil,
            topicId: nil,
            forwarded_from_original_author: nil
        )
    }
}
