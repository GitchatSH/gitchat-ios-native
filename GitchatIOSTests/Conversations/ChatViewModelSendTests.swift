import XCTest
@testable import Gitchat

@MainActor
final class ChatViewModelSendTests: XCTestCase {

    /// Each test gets a unique conversation ID so MessageCache.shared
    /// doesn't bleed optimistic messages between tests.
    private func makeConversation() -> Conversation {
        .testFixture(id: "conv-\(UUID().uuidString)")
    }

    func test_send_appendsOptimisticMessage_andEnqueuesPending() {
        let mock = MockAPIClient()
        // Stub send to hang forever so we can inspect pre-delivery state.
        mock.sendStub = { _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000_000)
            return Message.testFixture()
        }
        let store = OutboxStore(api: mock)
        let vm = ChatViewModel.testInstance(conversation: makeConversation(), outbox: store)

        vm.send(content: "hi")

        XCTAssertEqual(vm.messages.count, 1)
        let opt = vm.messages.first!
        XCTAssertTrue(opt.id.hasPrefix("local-"), "Expected id to start with 'local-', got \(opt.id)")
        XCTAssertNotNil(opt.client_message_id)
        XCTAssertEqual(opt.id, "local-\(opt.client_message_id!)")
        XCTAssertEqual(opt.content, "hi")

        let queued = store.pending(conversationID: vm.conversation.id).first
        XCTAssertNotNil(queued, "Expected a pending message in OutboxStore")
        XCTAssertEqual(queued?.clientMessageID, opt.client_message_id)
        XCTAssertEqual(queued?.content, "hi")
        XCTAssertTrue(queued?.attachments.isEmpty == true)
    }

    func test_send_withAttachments_passesPendingAttachments() {
        let mock = MockAPIClient()
        mock.sendStub = { _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000_000)
            return Message.testFixture()
        }
        mock.uploadStub = { _, _, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000_000)
            return UploadedRef(url: "", storagePath: "", sizeBytes: 0)
        }
        let store = OutboxStore(api: mock)
        let vm = ChatViewModel.testInstance(conversation: makeConversation(), outbox: store)

        let att = PendingAttachment(
            clientAttachmentID: "a",
            sourceData: Data([0xFF]),
            mimeType: "image/jpeg",
            width: 100,
            height: 200,
            blurhash: nil
        )
        vm.send(content: "look", attachments: [att])

        XCTAssertEqual(vm.messages.count, 1)
        let opt = vm.messages.first!
        XCTAssertTrue(opt.id.hasPrefix("local-"))
        XCTAssertEqual(opt.content, "look")

        let queued = store.pending(conversationID: vm.conversation.id).first!
        XCTAssertEqual(queued.attachments.count, 1)
        XCTAssertEqual(queued.attachments.first?.clientAttachmentID, "a")
        XCTAssertEqual(queued.content, "look")
    }

    func test_send_withEmptyContentAndNoAttachments_noOp() {
        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(conversation: makeConversation(), outbox: store)

        vm.send(content: "", attachments: [])

        XCTAssertEqual(vm.messages.count, 0)
        XCTAssertEqual(store.pending(conversationID: vm.conversation.id).count, 0)
    }

    func test_send_whitespaceOnly_noOp() {
        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(conversation: makeConversation(), outbox: store)

        vm.send(content: "   \n\t  ")

        XCTAssertEqual(vm.messages.count, 0)
        XCTAssertEqual(store.pending(conversationID: vm.conversation.id).count, 0)
    }
}
