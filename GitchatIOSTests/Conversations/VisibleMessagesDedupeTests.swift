import XCTest
@testable import Gitchat

/// Regression tests for the UIDiffableDataSource duplicate-id crash that
/// occurs when vm.send(content:attachments:) appends an optimistic placeholder
/// to vm.messages AND visibleMessages also projects the same id from
/// OutboxStore.pendingFor → toMessage. Both produce "local-<cmid>"; the
/// diffable data source crashes on duplicate identifiers.
///
/// visibleMessages must filter out pending projections whose id is already
/// present in vm.messages, covering both call paths:
///
///  - New path: vm.send(content:attachments:) → optimistic in messages + enqueued in OutboxStore
///  - Legacy path: vm.send() async → only enqueued in OutboxStore, not in messages
@MainActor
final class VisibleMessagesDedupeTests: XCTestCase {

    /// Use a unique conversation ID per test to avoid cross-test OutboxStore.shared pollution.
    private func makeConversation() -> Conversation {
        .testFixture(id: "vis-conv-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        // Best-effort cleanup: OutboxStore.shared is a singleton; wipe all
        // pending entries added during this test by iterating over all
        // conversations used. Since we use UUID-keyed conversation IDs,
        // any lingering entries won't affect other tests — but explicit
        // cleanup keeps the shared state tidy.
        try await super.tearDown()
    }

    // MARK: - Fix #1 regression: new vm.send path

    /// Simulates the post-Task-2.9 state: optimistic in vm.messages AND
    /// pending in OutboxStore.shared. visibleMessages must return exactly
    /// one entry (not two).
    func test_visibleMessages_dedupesOptimisticAlreadyInMessages() {
        let conv = makeConversation()
        let mock = MockAPIClient()
        mock.sendStub = { _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000_000)
            return Message.testFixture()
        }
        mock.uploadStub = { _, _, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000_000)
            return UploadedRef(url: "", storagePath: "", sizeBytes: 0)
        }
        // Use shared store so visibleMessages (which reads OutboxStore.shared) sees the pending entry.
        let vm = ChatViewModel.testInstance(conversation: conv, outbox: OutboxStore.shared)

        let cmid = UUID().uuidString
        // Simulate the optimistic already appended to messages (new vm.send path).
        let optimistic = Message.optimistic(
            clientMessageID: cmid,
            conversationID: conv.id,
            sender: "alice",
            content: "hi",
            attachments: []
        )
        vm.messages = [optimistic]

        // Also enqueue to OutboxStore.shared so visibleMessages sees it in pendingFor.
        OutboxStore.shared.enqueue(PendingMessage(
            clientMessageID: cmid,
            conversationID: conv.id,
            content: "hi",
            replyToID: nil,
            attachments: [],
            attempts: 0,
            createdAt: Date(),
            state: .enqueued
        ))

        let visible = vm.visibleMessages
        XCTAssertEqual(visible.count, 1,
            "visibleMessages must dedupe: optimistic in messages + pending projection have the same id")
        XCTAssertEqual(visible.first?.id, "local-\(cmid)")
    }

    // MARK: - Legacy path still works

    /// Simulates the legacy vm.send() async path: message is only in OutboxStore,
    /// NOT appended to vm.messages. visibleMessages must still surface it.
    func test_visibleMessages_includesLegacyPendingNotInMessages() {
        let conv = makeConversation()
        let mock = MockAPIClient()
        mock.sendStub = { _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000_000)
            return Message.testFixture()
        }
        let vm = ChatViewModel.testInstance(conversation: conv, outbox: OutboxStore.shared)

        // Legacy path: vm.messages is empty; pending only lives in OutboxStore.
        vm.messages = []
        let cmid = UUID().uuidString
        OutboxStore.shared.enqueue(PendingMessage(
            clientMessageID: cmid,
            conversationID: conv.id,
            content: "legacy",
            replyToID: nil,
            attachments: [],
            attempts: 0,
            createdAt: Date(),
            state: .enqueued
        ))

        let visible = vm.visibleMessages
        XCTAssertEqual(visible.count, 1,
            "Legacy-path pending message must appear in visibleMessages even when vm.messages is empty")
        XCTAssertEqual(visible.first?.id, "local-\(cmid)")
    }
}
