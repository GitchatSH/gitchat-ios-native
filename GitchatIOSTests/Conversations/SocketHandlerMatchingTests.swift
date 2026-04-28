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
