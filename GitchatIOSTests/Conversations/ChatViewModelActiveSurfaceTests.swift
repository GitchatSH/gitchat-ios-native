import XCTest
@testable import Gitchat

/// Regression: the unread-count bumping used to live inside
/// `ChatViewModel.handle(topicEvent:)`, which meant badges stopped
/// updating the moment the chat detail was dismissed. The new design
/// moves bumping into `TopicListStore.applyEvent(.message)` gated on
/// `activeSurfaceId`. ChatViewModel's only responsibility now is to
/// declare itself active for its target, and stand down on target swap
/// or deallocation. These tests pin that handoff contract.
@MainActor
final class ChatViewModelActiveSurfaceTests: XCTestCase {

    override func setUp() async throws {
        // Shared store leaks state between tests; reset.
        TopicListStore.shared.setActiveSurface(nil)
    }

    override func tearDown() async throws {
        TopicListStore.shared.setActiveSurface(nil)
    }

    func test_init_withTopicTarget_marksTopicActive() {
        let parent = Conversation.fixture(id: "parent-1")
        let topic = Topic.fixture(id: "topic-1", parentId: parent.id)
        let outbox = OutboxStore(api: MockAPIClient())

        _ = ChatViewModel(target: .topic(topic, parent: parent), outbox: outbox)

        XCTAssertEqual(TopicListStore.shared.activeSurfaceId, "topic-1")
    }

    func test_init_withConversationTarget_marksConversationActive() {
        let conv = Conversation.fixture(id: "dm-1")
        let outbox = OutboxStore(api: MockAPIClient())

        _ = ChatViewModel(conversation: conv, outbox: outbox)

        XCTAssertEqual(TopicListStore.shared.activeSurfaceId, "dm-1")
    }

    func test_setTarget_updatesActiveSurface() {
        let parent = Conversation.fixture(id: "parent-1")
        let topicA = Topic.fixture(id: "topic-a", parentId: parent.id)
        let topicB = Topic.fixture(id: "topic-b", parentId: parent.id)
        let outbox = OutboxStore(api: MockAPIClient())

        let vm = ChatViewModel(target: .topic(topicA, parent: parent), outbox: outbox)
        XCTAssertEqual(TopicListStore.shared.activeSurfaceId, "topic-a")

        vm.setTarget(.topic(topicB, parent: parent))
        XCTAssertEqual(TopicListStore.shared.activeSurfaceId, "topic-b")
    }

    func test_deallocation_clearsActiveSurface() async {
        let parent = Conversation.fixture(id: "parent-1")
        let topic = Topic.fixture(id: "topic-deinit", parentId: parent.id)
        let outbox = OutboxStore(api: MockAPIClient())

        autoreleasepool {
            _ = ChatViewModel(target: .topic(topic, parent: parent), outbox: outbox)
        }
        // Deinit hops to MainActor via Task — let it run.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(TopicListStore.shared.activeSurfaceId,
                     "deinit must clear activeSurfaceId so subsequent topic messages bump unread")
    }

    func test_deallocation_doesNotOverwriteAnotherActiveSurface() async {
        // SwiftUI race: chat A's deinit can fire AFTER chat B's init in
        // some navigation transitions. A must not unset B.
        let parent = Conversation.fixture(id: "parent-1")
        let topicA = Topic.fixture(id: "topic-a", parentId: parent.id)
        let topicB = Topic.fixture(id: "topic-b", parentId: parent.id)
        let outbox = OutboxStore(api: MockAPIClient())

        autoreleasepool {
            _ = ChatViewModel(target: .topic(topicA, parent: parent), outbox: outbox)
            // Simulate B opening before A's refcount actually drops.
            TopicListStore.shared.setActiveSurface("topic-b")
            _ = topicB
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(TopicListStore.shared.activeSurfaceId, "topic-b",
                       "A's deinit must NOT clear B's active flag")
    }
}
