import XCTest
@testable import Gitchat

@MainActor
final class MergeFromServerTests: XCTestCase {
    func test_serverMessage_replacesOptimistic_byClientMessageID() {
        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(outbox: store)
        let cmid = "cmid-merge-1"
        let opt = Message.optimistic(
            clientMessageID: cmid, conversationID: vm.conversation.id,
            sender: "alice", content: "hi", attachments: []
        )
        vm.messages = [opt]

        let srv = makeServerMessage(id: "srv-1", cmid: cmid, conversationID: vm.conversation.id, content: "hi")
        vm.mergeFromServer([srv])

        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.id, "srv-1")
        XCTAssertEqual(vm.messages.first?.client_message_id, cmid)
    }

    func test_serverMessage_appendedWhenNoMatch() {
        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(outbox: store)
        vm.messages = []

        let srv = makeServerMessage(id: "srv-2", cmid: nil, conversationID: vm.conversation.id, content: "yo")
        vm.mergeFromServer([srv])

        XCTAssertEqual(vm.messages.map(\.id), ["srv-2"])
    }

    func test_orphanLocalCmid_cleanedWhenServerArrivesUnderDifferentBranch() {
        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(outbox: store)
        let cmid = "cmid-orphan-1"
        let opt = Message.optimistic(
            clientMessageID: cmid, conversationID: vm.conversation.id,
            sender: "alice", content: "x", attachments: []
        )
        vm.messages = [opt]

        // Server returns the message under its real id, with cmid populated
        let srv = makeServerMessage(id: "srv-orphan", cmid: cmid, conversationID: vm.conversation.id, content: "x")
        vm.mergeFromServer([srv])

        XCTAssertFalse(vm.messages.contains(where: { $0.id == "local-\(cmid)" }))
        XCTAssertTrue(vm.messages.contains(where: { $0.id == "srv-orphan" }))
        XCTAssertEqual(vm.messages.count, 1)
    }

    func test_legacyLocalWithoutCmid_isCleanedOnNextLoad() {
        // Pre-existing local-* in cache from old build; cmid=nil; server returns its real form
        let store = OutboxStore(api: MockAPIClient())
        let vm = ChatViewModel.testInstance(outbox: store)
        let legacy = makeMessage(
            id: "local-legacy-junk",
            cmid: nil,
            conversationID: vm.conversation.id,
            content: "junk"
        )
        vm.messages = [legacy]

        // Server returns nothing in the fetch (or returns unrelated messages); orphan local-* with nil cmid is junk
        vm.mergeFromServer([])

        // Plan §4.3: 'local-*' messages with nil cmid are legacy junk and removed on merge.
        XCTAssertEqual(vm.messages.count, 0, "legacy local-* without cmid should be cleaned even when fetched is empty")
    }

    // MARK: - helpers

    private func makeServerMessage(id: String, cmid: String?, conversationID: String, content: String) -> Message {
        return makeMessage(id: id, cmid: cmid, conversationID: conversationID, content: content)
    }

    private func makeMessage(id: String, cmid: String?, conversationID: String, content: String) -> Message {
        // Use the existing Message init or testFixture helper. Construct with all required fields.
        Message.testFixture(id: id, clientMessageID: cmid, conversationID: conversationID, content: content)
    }
}
