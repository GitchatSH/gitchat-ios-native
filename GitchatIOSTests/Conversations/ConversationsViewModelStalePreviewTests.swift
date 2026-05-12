import XCTest
@testable import Gitchat

/// Regression tests for the chat-list stale-preview bug: receiver's
/// conversation list got stuck on an older message body (e.g. "5") while
/// the message-create UPDATE race window on BE was open and an
/// out-of-order socket event applied an older message. BE fix lives in
/// gitchat-webapp/backend/src/modules/messages/services/messages.service.ts:1516.
@MainActor
final class ConversationsViewModelStalePreviewTests: XCTestCase {

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
