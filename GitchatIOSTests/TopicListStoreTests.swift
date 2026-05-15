import XCTest
// Module name is `Gitchat` (PRODUCT_NAME in project.yml), not `GitchatIOS`.
@testable import Gitchat

@MainActor
final class TopicListStoreTests: XCTestCase {

    func testAppendInsertsTopicForParent() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t1", parentId: "p1"), parentId: "p1")
        XCTAssertEqual(store.topics(forParent: "p1").count, 1)
    }

    func testSortPinnedBeforeUnpinned() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "u1", parentId: "p"), parentId: "p")
        store.append(Topic.fixture(id: "p2", parentId: "p", pinOrder: 2), parentId: "p")
        store.append(Topic.fixture(id: "p1", parentId: "p", pinOrder: 1), parentId: "p")

        let order = store.topics(forParent: "p").map(\.id)
        XCTAssertEqual(order, ["p1", "p2", "u1"])  // pin asc, then unpinned
    }

    func testArchiveRemovesFromList() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t1", parentId: "p"), parentId: "p")
        store.archive(topicId: "t1", parentId: "p")
        XCTAssertTrue(store.topics(forParent: "p").isEmpty)
    }

    func testApplyEventCreated() {
        let store = TopicListStore()
        let t = Topic.fixture(id: "t1", parentId: "p")
        store.applyEvent(.created(parentId: "p", topic: t))
        XCTAssertEqual(store.topics(forParent: "p").count, 1)
    }

    func testApplyEventPinnedReorders() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "a", parentId: "p"), parentId: "p")
        store.append(Topic.fixture(id: "b", parentId: "p"), parentId: "p")
        store.applyEvent(.pinned(parentId: "p", topicId: "b", pinOrder: 1))
        XCTAssertEqual(store.topics(forParent: "p").map(\.id), ["b", "a"])
    }

    func testBumpUnreadIncrementsCount() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t", parentId: "p", unread: 2), parentId: "p")
        store.bumpUnread(topicId: "t", parentId: "p", by: 1)
        XCTAssertEqual(store.topics(forParent: "p").first?.unread_count, 3)
    }

    func testApplyEventMessage_updatesPreviewAndTimestampAndSender() {
        // Regression: topic list view stayed stuck on the previous message
        // body when a `topic:message` socket event arrived (case was a
        // no-op in applyEvent), so receivers on the topic list saw a
        // preview that lagged the actual conversation.
        let store = TopicListStore()
        let t = Topic.fixture(id: "t1", parentId: "p")
        store.append(t, parentId: "p")

        let msg = Message.testFixture(
            id: "srv-1", clientMessageID: nil, conversationID: "t1",
            sender: "bob", content: "hello world"
        )
        store.applyEvent(.message(parentId: "p", topicId: "t1", message: msg))

        let updated = store.topics(forParent: "p").first
        XCTAssertEqual(updated?.last_message_preview, "hello world")
        XCTAssertEqual(updated?.last_sender_login, "bob")
        XCTAssertEqual(updated?.last_message_at, "2026-04-28T10:00:00.000Z")
    }

    func testApplyEventMessage_bumpsUnread_whenNoActiveSurface() {
        // Regression for the chat-list stale badge bug: when the user has
        // exited every chat detail (no ChatViewModel alive), incoming
        // `.message` events still need to bump the topic row's unread
        // count. Previously this was deferred to ChatViewModel and got
        // lost whenever the chat detail was dismissed.
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t1", parentId: "p", unread: 3), parentId: "p")

        let msg = Message.testFixture(
            id: "srv-2", clientMessageID: nil, conversationID: "t1",
            sender: "bob", content: "new msg"
        )
        store.applyEvent(.message(parentId: "p", topicId: "t1", message: msg))

        XCTAssertEqual(store.topics(forParent: "p").first?.unread_count, 4)
    }

    func testApplyEventMessage_bumpsUnread_whenDifferentSurfaceIsActive() {
        // User is in chat detail for topic t1 but a message arrives for
        // topic t2. t2 must bump.
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t1", parentId: "p", unread: 0), parentId: "p")
        store.append(Topic.fixture(id: "t2", parentId: "p", unread: 1), parentId: "p")
        store.setActiveSurface("t1")

        let msg = Message.testFixture(
            id: "srv-3", clientMessageID: nil, conversationID: "t2",
            sender: "bob", content: "for t2"
        )
        store.applyEvent(.message(parentId: "p", topicId: "t2", message: msg))

        XCTAssertEqual(store.topics(forParent: "p").first(where: { $0.id == "t2" })?.unread_count, 2)
    }

    func testApplyEventMessage_doesNotBumpUnread_whenSameSurfaceIsActive() {
        // User is currently viewing topic t1; the chat is open so the new
        // message is rendered in-chat — its badge must stay at 0.
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t1", parentId: "p", unread: 0), parentId: "p")
        store.setActiveSurface("t1")

        let msg = Message.testFixture(
            id: "srv-4", clientMessageID: nil, conversationID: "t1",
            sender: "bob", content: "while viewing"
        )
        store.applyEvent(.message(parentId: "p", topicId: "t1", message: msg))

        XCTAssertEqual(store.topics(forParent: "p").first?.unread_count, 0)
        // Preview MUST still update — the row reflects the latest body
        // for when the user backs out.
        XCTAssertEqual(store.topics(forParent: "p").first?.last_message_preview, "while viewing")
    }

    func testApplyEventMessage_bumpsUnread_afterUserExitsTheJustViewedChat() {
        // Reproduces the user-reported scenario verbatim: user opens a
        // chat, exits, and a new message arrives for that same chat.
        // The badge MUST bump (was 0) — the previous deinit-only release
        // missed this because SwiftUI retains the @StateObject after view
        // dismissal. Now the View calls `clearActiveSurface` on
        // `.onDisappear` so the store sees the surface as inactive.
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t1", parentId: "p", unread: 0), parentId: "p")

        // Enter chat → mark active.
        store.setActiveSurface("t1")
        // While inside, a message arrives — should NOT bump (we're reading).
        let msg1 = Message.testFixture(
            id: "srv-while-inside", clientMessageID: nil, conversationID: "t1",
            sender: "bob", content: "inside"
        )
        store.applyEvent(.message(parentId: "p", topicId: "t1", message: msg1))
        XCTAssertEqual(store.topics(forParent: "p").first?.unread_count, 0)

        // Exit chat → release surface (this is what `.onDisappear` does
        // in ChatDetailView).
        store.clearActiveSurface("t1")

        // Next message arrives — MUST bump now.
        let msg2 = Message.testFixture(
            id: "srv-after-exit", clientMessageID: nil, conversationID: "t1",
            sender: "bob", content: "after exit"
        )
        store.applyEvent(.message(parentId: "p", topicId: "t1", message: msg2))

        XCTAssertEqual(store.topics(forParent: "p").first?.unread_count, 1,
                       "After the user backs out of the chat, the next message MUST bump the badge")
        XCTAssertEqual(store.topics(forParent: "p").first?.last_message_preview, "after exit")
    }

    func testClearActiveSurface_onlyClearsIfMatching() {
        // Race protection: A.deinit firing after B.init (rare SwiftUI
        // lifecycle interleave) must NOT wipe B's active flag.
        let store = TopicListStore()
        store.setActiveSurface("B")
        store.clearActiveSurface("A")  // A is stale
        XCTAssertEqual(store.activeSurfaceId, "B")
        store.clearActiveSurface("B")
        XCTAssertNil(store.activeSurfaceId)
    }

    func testApplyEventMessage_monotonicGuardSkipsOutOfOrderOlderMessage() {
        // Out-of-order delivery (delayed retry, socket reordering) shouldn't
        // roll the topic's preview back to an older message.
        let store = TopicListStore()
        let baseTopic = Topic(
            id: "t1", parent_conversation_id: "p", name: "T",
            icon_emoji: nil, color_token: nil, is_general: false,
            pin_order: nil, archived_at: nil,
            last_message_at: "2026-05-12T14:25:00.500Z",
            last_message_preview: "6",
            last_sender_login: "alice",
            unread_count: 0, unread_mentions_count: 0, unread_reactions_count: 0,
            created_by: "x", created_at: "2026-04-20T08:00:00Z"
        )
        store.append(baseTopic, parentId: "p")

        // Older message arrives late — must be ignored.
        let olderMsg = Message(
            id: "srv-old", client_message_id: nil, conversation_id: "t1",
            sender: "bob", sender_avatar: nil, content: "5",
            created_at: "2026-05-12T14:25:00.100Z",
            edited_at: nil, reactions: nil, attachment_url: nil,
            type: "user", reply_to_id: nil, reply: nil, attachments: nil,
            unsent_at: nil, reactionRows: nil, topicId: nil,
            forwarded_from_original_author: nil
        )
        store.applyEvent(.message(parentId: "p", topicId: "t1", message: olderMsg))

        let topic = store.topics(forParent: "p").first
        XCTAssertEqual(topic?.last_message_preview, "6")
        XCTAssertEqual(topic?.last_message_at, "2026-05-12T14:25:00.500Z")
    }

    func testLRUEvictsOldestParent() {
        let store = TopicListStore(maxParents: 2)
        store.append(Topic.fixture(id: "x", parentId: "p1"), parentId: "p1")
        store.append(Topic.fixture(id: "x", parentId: "p2"), parentId: "p2")
        store.append(Topic.fixture(id: "x", parentId: "p3"), parentId: "p3")  // evicts p1
        XCTAssertTrue(store.topics(forParent: "p1").isEmpty)
        XCTAssertEqual(store.topics(forParent: "p2").count, 1)
        XCTAssertEqual(store.topics(forParent: "p3").count, 1)
    }
}
