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

    func testApplyEventMessage_doesNotTouchUnread_avoidingDoubleCountWithChatViewModel() {
        // ChatViewModel.handle(topicEvent:) already calls bumpUnread when
        // a chat detail is active for a different topic. Bumping here
        // would double-count when both subscribers are alive.
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t1", parentId: "p", unread: 3), parentId: "p")

        let msg = Message.testFixture(
            id: "srv-2", clientMessageID: nil, conversationID: "t1",
            sender: "bob", content: "new msg"
        )
        store.applyEvent(.message(parentId: "p", topicId: "t1", message: msg))

        XCTAssertEqual(store.topics(forParent: "p").first?.unread_count, 3)
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
