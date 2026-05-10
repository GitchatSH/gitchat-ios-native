import XCTest
@testable import Gitchat

@MainActor
final class SocketHandlerMatchingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChatMessageView.seenIds.removeAll()
    }

    // MARK: - makeSocketMessageSentHandler

    func test_inboundMessage_withMatchingCmid_replacesOptimistic() {
        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(outbox: store)
        let cmid = "cmid-W"
        vm.messages = [Message.optimistic(
            clientMessageID: cmid,
            conversationID: vm.conversation.id,
            sender: "alice",
            content: "x",
            attachments: []
        )]

        let handler = ChatDetailViewBindings.makeSocketMessageSentHandler(vm: vm)
        let inbound = Message.testFixture(
            id: "srv-W",
            clientMessageID: cmid,
            conversationID: vm.conversation.id,
            content: "x"
        )
        handler(inbound)

        XCTAssertEqual(vm.messages.count, 1, "Optimistic placeholder should be replaced, not appended")
        XCTAssertEqual(vm.messages.first?.id, "srv-W", "Placeholder id should be replaced with server id")
    }

    func test_inboundMessage_noMatch_appendsViaSeenIdsDedup() {
        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(outbox: store)
        vm.messages = []

        let handler = ChatDetailViewBindings.makeSocketMessageSentHandler(vm: vm)
        let m1 = Message.testFixture(
            id: "srv-A",
            clientMessageID: nil,
            conversationID: vm.conversation.id,
            content: "yo"
        )
        handler(m1)
        handler(m1) // second call should be deduped

        XCTAssertEqual(vm.messages.count, 1, "Duplicate socket event should be deduped via seenIds")
    }

    func test_inboundMessage_wrongConversation_isIgnored() {
        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(outbox: store)
        vm.messages = []

        let handler = ChatDetailViewBindings.makeSocketMessageSentHandler(vm: vm)
        let inbound = Message.testFixture(
            id: "srv-other",
            clientMessageID: nil,
            conversationID: "other-conv",
            content: "wrong"
        )
        handler(inbound)

        XCTAssertEqual(vm.messages.count, 0, "Message for a different conversation should be ignored")
    }

    /// Regression: BE broadcasts topic messages with `msg.conversation_id = topicId`
    /// to the parent room. The old guard `vm.conversation.id` (= parent for topic
    /// targets) silently rejected every topic message — receivers had to back out
    /// + re-enter to fetch via GET. Match against `target.conversationId` instead.
    func test_inboundMessage_topicTarget_appendsWhenMatchingTopicId() {
        let store = OutboxStore(api: MockAPIClient())
        let parent = Conversation.fixture(id: "parent-conv")
        let topic = Topic.fixture(id: "topic-1", parentId: parent.id)
        let vm = ChatViewModel(target: .topic(topic, parent: parent), outbox: store)
        vm.messages = []

        let handler = ChatDetailViewBindings.makeSocketMessageSentHandler(vm: vm)
        let inbound = Message.testFixture(
            id: "srv-topic-1",
            clientMessageID: nil,
            conversationID: topic.id,
            content: "topic msg"
        )
        handler(inbound)

        XCTAssertEqual(vm.messages.count, 1, "Topic message must reach the receiver in the active topic")
        XCTAssertEqual(vm.messages.first?.id, "srv-topic-1")
    }

    /// In a topic target, a message broadcast for the parent conversation
    /// (different surface) must NOT appear in the topic view.
    func test_inboundMessage_topicTarget_ignoresParentConversationMessage() {
        let store = OutboxStore(api: MockAPIClient())
        let parent = Conversation.fixture(id: "parent-conv")
        let topic = Topic.fixture(id: "topic-1", parentId: parent.id)
        let vm = ChatViewModel(target: .topic(topic, parent: parent), outbox: store)
        vm.messages = []

        let handler = ChatDetailViewBindings.makeSocketMessageSentHandler(vm: vm)
        let inbound = Message.testFixture(
            id: "srv-parent-1",
            clientMessageID: nil,
            conversationID: parent.id,
            content: "parent msg"
        )
        handler(inbound)

        XCTAssertEqual(vm.messages.count, 0, "Parent-room messages must not bleed into the topic view")
    }

    // MARK: - makeOutboxDeliveryHandler

    func test_outboxDelivery_withMatchingCmid_replacesOptimistic() {
        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(outbox: store)
        let cmid = "cmid-X"
        vm.messages = [Message.optimistic(
            clientMessageID: cmid,
            conversationID: vm.conversation.id,
            sender: "bob",
            content: "hello",
            attachments: []
        )]

        let handler = ChatDetailViewBindings.makeOutboxDeliveryHandler(vm: vm)
        let confirmed = Message.testFixture(
            id: "srv-X",
            clientMessageID: cmid,
            conversationID: vm.conversation.id,
            content: "hello"
        )
        handler(confirmed)

        XCTAssertEqual(vm.messages.count, 1, "Outbox delivery should replace optimistic, not append")
        XCTAssertEqual(vm.messages.first?.id, "srv-X")
    }

    func test_outboxDelivery_duplicate_isDeduped() {
        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(outbox: store)
        vm.messages = []

        let handler = ChatDetailViewBindings.makeOutboxDeliveryHandler(vm: vm)
        let msg = Message.testFixture(id: "srv-Y", clientMessageID: nil, conversationID: vm.conversation.id)
        handler(msg)
        handler(msg)

        XCTAssertEqual(vm.messages.count, 1, "Duplicate delivery should be deduped via seenIds")
    }
}
