import XCTest
@testable import Gitchat

@MainActor
final class MessageCacheFilterTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        // Clean up cache entries created during tests to avoid cross-test pollution
        MessageCache.shared.clearForTesting()
    }

    func test_persistCache_excludesLocalPrefixedMessages() {
        let convId = "conv-cache-\(UUID().uuidString)"
        let store = OutboxStore(api: MockAPIClient())
        let conv = Conversation.testFixture(id: convId)
        let vm = ChatViewModel.testInstance(conversation: conv, outbox: store)

        let local = Message.optimistic(
            clientMessageID: "x", conversationID: convId,
            sender: "alice", content: "opt", attachments: []
        )
        let server = Message.testFixture(id: "srv-y", clientMessageID: nil, conversationID: convId, content: "real")
        vm.messages = [local, server]

        vm.persistCache()

        let stored = MessageCache.shared.get(convId)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.messages.map(\.id), ["srv-y"])
    }

    func test_init_filtersLocalPrefixedMessagesFromCache() {
        let convId = "conv-cache-load-\(UUID().uuidString)"
        let conv = Conversation.testFixture(id: convId)

        let local = Message.testFixture(id: "local-junk", clientMessageID: "x", conversationID: convId, content: "junk")
        let real = Message.testFixture(id: "srv-real", clientMessageID: nil, conversationID: convId, content: "ok")
        MessageCache.shared.store(convId, entry: MessageCache.Entry(
            messages: [local, real],
            nextCursor: nil,
            otherReadAt: nil,
            readCursors: nil,
            fetchedAt: Date()
        ))

        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(conversation: conv, outbox: store)
        XCTAssertEqual(vm.messages.map(\.id), ["srv-real"])
    }
}
