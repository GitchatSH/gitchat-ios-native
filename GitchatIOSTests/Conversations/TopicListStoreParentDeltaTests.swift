import XCTest
import Combine
@testable import Gitchat

/// Validates the `parentUnreadDeltas` publisher on `TopicListStore`.
/// The store is the single source of truth for topic-level unread
/// changes; it publishes a true delta (`newClamped - old`) so the
/// outer Chats list can keep its team-row badge in sync without
/// refetching. Spec: `docs/superpowers/specs/2026-05-16-topic-unread-bubble-to-team-design.md`.
@MainActor
final class TopicListStoreParentDeltaTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func makeStore() -> TopicListStore {
        let defaults = UserDefaults(suiteName: "TopicListStoreParentDeltaTests-\(UUID().uuidString)")!
        return TopicListStore(maxParents: 10, defaults: defaults)
    }

    func test_bumpUnread_emitsParentDeltaOfOne() {
        let store = makeStore()
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 0),
        ], forParent: "team-1")

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        store.bumpUnread(topicId: "t1", parentId: "team-1", by: 1)

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.parentId, "team-1")
        XCTAssertEqual(observed.first?.delta, 1)
    }

    func test_bumpUnread_emitsNothing_whenTopicMissing() {
        let store = makeStore()
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 0),
        ], forParent: "team-1")

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        store.bumpUnread(topicId: "t-unknown", parentId: "team-1", by: 1)
        XCTAssertTrue(observed.isEmpty)
    }

    func test_clearUnread_emitsNegativeDeltaEqualToPriorCount() {
        let store = makeStore()
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 4),
        ], forParent: "team-1")

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        store.clearUnread(topicId: "t1", parentId: "team-1")

        // Must emit the true delta (-4), not -Int.max — saturation is
        // an internal implementation detail.
        XCTAssertEqual(observed.first?.delta, -4)
    }

    func test_clearUnread_emitsNothing_whenAlreadyZero() {
        let store = makeStore()
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 0),
        ], forParent: "team-1")

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        store.clearUnread(topicId: "t1", parentId: "team-1")
        XCTAssertTrue(observed.isEmpty, "Clearing an already-zero unread must not emit a spurious delta.")
    }

    func test_bumpUnread_negativeDelta_clampsToFloorAndEmitsTrueDelta() {
        let store = makeStore()
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 3),
        ], forParent: "team-1")

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        // Caller asks for -10, clamp pulls newCount to 0, so the true delta is -3.
        store.bumpUnread(topicId: "t1", parentId: "team-1", by: -10)

        XCTAssertEqual(observed.first?.delta, -3)
    }

    func test_messageEvent_emitsDeltaOfOne_whenNotActiveSurface() {
        let store = makeStore()
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 2),
        ], forParent: "team-1")
        store.setActiveSurface(nil)

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        let evt = TopicSocketEvent.message(
            parentId: "team-1",
            topicId: "t1",
            message: Message.testFixture(
                conversationID: "t1",
                content: "new"
            )
        )
        store.applyEvent(evt)

        XCTAssertEqual(observed.first?.delta, 1)
    }

    func test_messageEvent_emitsNothing_whenIsActiveSurface() {
        let store = makeStore()
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 2),
        ], forParent: "team-1")
        store.setActiveSurface("t1")

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        let evt = TopicSocketEvent.message(
            parentId: "team-1",
            topicId: "t1",
            message: Message.testFixture(
                conversationID: "t1",
                content: "new"
            )
        )
        store.applyEvent(evt)

        XCTAssertTrue(observed.isEmpty,
            "Active surface must suppress both the topic bump and the parent delta.")
    }

    func test_messageEvent_emitsNothing_whenOlderMessageThanLast() {
        // The monotonic guard inside `.message` short-circuits the topic
        // update if the incoming message is older than `last_message_at`.
        // We must NOT bump unread in that case either.
        let store = makeStore()
        // Topic already has a newer last_message_at than the inbound msg.
        let existing = Topic(
            id: "t1", parent_conversation_id: "team-1", name: "T",
            icon_emoji: nil, color_token: nil, is_general: false,
            pin_order: nil, archived_at: nil,
            last_message_at: "2099-01-01T00:00:00Z",
            last_message_preview: "fresh",
            last_sender_login: "bob",
            unread_count: 0,
            unread_mentions_count: 0,
            unread_reactions_count: 0,
            created_by: "x", created_at: "2026-04-20T08:00:00Z"
        )
        store.setTopics([existing], forParent: "team-1")
        store.setActiveSurface(nil)

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        let olderMsg = Message.testFixture(
            conversationID: "t1",
            content: "stale"
        )
        let evt = TopicSocketEvent.message(
            parentId: "team-1", topicId: "t1", message: olderMsg
        )
        store.applyEvent(evt)

        XCTAssertTrue(observed.isEmpty)
    }
}
