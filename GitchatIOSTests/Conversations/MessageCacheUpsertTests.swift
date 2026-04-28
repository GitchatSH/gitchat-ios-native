import XCTest
@testable import Gitchat

@MainActor
final class MessageCacheUpsertTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        MessageCache.shared.clearForTesting()
    }

    func test_upsertDelivered_intoEmptyCache_isNoOp() {
        let convId = "conv-cache-empty-\(UUID().uuidString)"
        let msg = Message.testFixture(id: "srv-1", clientMessageID: "cmid-1", conversationID: convId)
        MessageCache.shared.upsertDelivered(conversationID: convId, message: msg)
        XCTAssertNil(MessageCache.shared.get(convId), "no entry exists; upsert should be a no-op")
    }

    func test_upsertDelivered_appendsWhenNoMatch() {
        let convId = "conv-cache-append-\(UUID().uuidString)"
        let existing = Message.testFixture(id: "srv-existing", clientMessageID: nil, conversationID: convId)
        MessageCache.shared.store(convId, entry: MessageCache.Entry(
            messages: [existing], nextCursor: nil, otherReadAt: nil, readCursors: nil, fetchedAt: Date()
        ))

        let new = Message.testFixture(id: "srv-new", clientMessageID: "cmid-new", conversationID: convId)
        MessageCache.shared.upsertDelivered(conversationID: convId, message: new)

        let entry = MessageCache.shared.get(convId)!
        XCTAssertEqual(entry.messages.map(\.id), ["srv-existing", "srv-new"])
    }

    func test_upsertDelivered_replacesByClientMessageID() {
        let convId = "conv-cache-replace-cmid-\(UUID().uuidString)"
        // Cache happens to have an optimistic with cmid (e.g., from a stale write)
        let optimistic = Message.testFixture(id: "local-X", clientMessageID: "cmid-X", conversationID: convId)
        let other = Message.testFixture(id: "srv-other", clientMessageID: nil, conversationID: convId)
        MessageCache.shared.store(convId, entry: MessageCache.Entry(
            messages: [other, optimistic], nextCursor: nil, otherReadAt: nil, readCursors: nil, fetchedAt: Date()
        ))

        let server = Message.testFixture(id: "srv-X", clientMessageID: "cmid-X", conversationID: convId)
        MessageCache.shared.upsertDelivered(conversationID: convId, message: server)

        let entry = MessageCache.shared.get(convId)!
        // Optimistic stripped (defense-in-depth), server message present, no duplicate.
        XCTAssertFalse(entry.messages.contains { $0.id == "local-X" })
        XCTAssertTrue(entry.messages.contains { $0.id == "srv-X" })
        XCTAssertEqual(entry.messages.filter { $0.client_message_id == "cmid-X" }.count, 1)
    }

    func test_upsertDelivered_idempotent_onSecondCall() {
        let convId = "conv-cache-idempotent-\(UUID().uuidString)"
        MessageCache.shared.store(convId, entry: MessageCache.Entry(
            messages: [], nextCursor: nil, otherReadAt: nil, readCursors: nil, fetchedAt: Date()
        ))
        let m = Message.testFixture(id: "srv-z", clientMessageID: "cmid-z", conversationID: convId)
        MessageCache.shared.upsertDelivered(conversationID: convId, message: m)
        MessageCache.shared.upsertDelivered(conversationID: convId, message: m)
        let entry = MessageCache.shared.get(convId)!
        XCTAssertEqual(entry.messages.count, 1)
    }
}
