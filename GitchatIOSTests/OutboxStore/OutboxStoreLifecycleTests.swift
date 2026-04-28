import XCTest
@testable import Gitchat

// MARK: - State-match helper (used by cancel no-op test)

private func statesMatch(_ lhs: PendingMessage.State, _ rhs: PendingMessage.State) -> Bool {
    switch (lhs, rhs) {
    case (.enqueued,  .enqueued),
         (.uploaded,  .uploaded),
         (.sending,   .sending),
         (.delivered, .delivered):
        return true
    case (.uploading, .uploading):
        return true
    case (.failed, .failed):
        return true
    default:
        return false
    }
}

@MainActor
private func waitForState(
    store: OutboxStore,
    cmid: String,
    conv: String,
    state: PendingMessage.State,
    timeout: TimeInterval
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let p = store.pending(conversationID: conv).first(where: { $0.clientMessageID == cmid }),
           statesMatch(p.state, state) {
            return
        }
        try await Task.sleep(nanoseconds: 30_000_000) // 30 ms poll
    }
    throw NSError(
        domain: "TestHelper", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "waitForState(\(state)) timed out for cmid \(cmid)"]
    )
}

// MARK: - Tests

@MainActor
final class OutboxStoreLifecycleTests: XCTestCase {

    // MARK: - Text-only send

    func test_textOnly_skipsUploading_endsInDelivered_invokesHandler() async throws {
        let mock = MockAPIClient()
        mock.sendStub = { conv, body, _, _, cmid in
            Message.testFixture(
                id: "srv-text",
                clientMessageID: cmid,
                conversationID: conv,
                content: body
            )
        }

        let store = OutboxStore(api: mock)

        var delivered: Message?
        store.registerDeliveryHandler(conversationID: "c1") { msg in
            delivered = msg
        }

        store.enqueue(PendingMessage(
            clientMessageID: "cmid-text-1",
            conversationID: "c1",
            content: "hello",
            replyToID: nil,
            attachments: [],
            attempts: 0,
            createdAt: Date(),
            state: .enqueued
        ))

        try await store.waitUntilIdle(timeout: 2.0)

        XCTAssertNotNil(delivered, "Delivery handler should have been invoked")
        XCTAssertEqual(delivered?.client_message_id, "cmid-text-1")
        XCTAssertEqual(delivered?.id, "srv-text")
    }

    // MARK: - Attachment send

    func test_withAttachments_transitions_enqueued_uploading_uploaded_sending_delivered() async throws {
        let mock = MockAPIClient()

        var uploadCount = 0
        mock.uploadStub = { _, data, _ in
            uploadCount += 1
            try await Task.sleep(nanoseconds: 30_000_000) // simulate latency
            return UploadedRef(url: "https://cdn/x.jpg", storagePath: "p/x.jpg", sizeBytes: data.count)
        }

        var sendArgs: (body: String, attachments: [[String: Any]], cmid: String?)?
        mock.sendStub = { conv, body, attachments, _, cmid in
            sendArgs = (body, attachments, cmid)
            return Message.testFixture(
                id: "srv-img",
                clientMessageID: cmid,
                conversationID: conv,
                content: body
            )
        }

        let store = OutboxStore(api: mock)
        var delivered: Message?
        store.registerDeliveryHandler(conversationID: "c1") { delivered = $0 }

        let att = PendingAttachment(
            clientAttachmentID: "att-1",
            sourceData: Data([0xFF, 0xD8, 0xFF]),
            mimeType: "image/jpeg",
            width: 100,
            height: 200,
            blurhash: nil,
            uploaded: nil
        )
        store.enqueue(PendingMessage(
            clientMessageID: "cmid-img-1",
            conversationID: "c1",
            content: "look",
            replyToID: nil,
            attachments: [att],
            attempts: 0,
            createdAt: Date(),
            state: .enqueued
        ))

        try await store.waitUntilIdle(timeout: 5.0)

        XCTAssertEqual(uploadCount, 1, "Upload should have been called exactly once")
        XCTAssertNotNil(delivered, "Delivery handler should have been invoked")
        XCTAssertEqual(delivered?.client_message_id, "cmid-img-1")

        let args = try XCTUnwrap(sendArgs, "sendMessage should have been called")
        XCTAssertEqual(args.body, "look")
        XCTAssertEqual(args.attachments.count, 1)
        XCTAssertEqual(args.attachments.first?["url"] as? String, "https://cdn/x.jpg")
        XCTAssertEqual(args.cmid, "cmid-img-1")
    }

    // MARK: - Task 2.7: Retry / backoff

    func test_serverReturns500_retriesWithBackoff_eventuallyDelivers() async throws {
        let mock = MockAPIClient()
        var attempts = 0
        mock.sendStub = { conv, body, _, _, cmid in
            attempts += 1
            if attempts < 3 {
                throw APIError.http(500, "internal server error")
            }
            return Message.testFixture(id: "srv-retried", clientMessageID: cmid, conversationID: conv, content: body)
        }

        let store = OutboxStore(api: mock, retryClock: ImmediateClock())

        var delivered: Message?
        store.registerDeliveryHandler(conversationID: "c1") { delivered = $0 }

        store.enqueue(PendingMessage(
            clientMessageID: "cmid-retry-1",
            conversationID: "c1",
            content: "x",
            replyToID: nil,
            attachments: [],
            attempts: 0,
            createdAt: Date(),
            state: .enqueued
        ))

        try await store.waitUntilIdle(timeout: 5.0)

        XCTAssertEqual(attempts, 3, "Should have attempted send 3 times (2 failures + 1 success)")
        XCTAssertNotNil(delivered, "Delivery handler should have been invoked after retry succeeds")
        XCTAssertEqual(delivered?.id, "srv-retried")
    }

    func test_serverReturns400_doesNotRetry_stateFailedNotRetriable() async throws {
        let mock = MockAPIClient()
        var attempts = 0
        mock.sendStub = { _, _, _, _, _ in
            attempts += 1
            throw APIError.http(400, "bad input")
        }

        let store = OutboxStore(api: mock, retryClock: ImmediateClock())
        let cmid = "cmid-bad-1"
        store.enqueue(PendingMessage(
            clientMessageID: cmid,
            conversationID: "c1",
            content: "x",
            replyToID: nil,
            attachments: [],
            attempts: 0,
            createdAt: Date(),
            state: .enqueued
        ))

        try await store.waitUntilIdle(timeout: 2.0)

        XCTAssertEqual(attempts, 1, "4xx errors must not be retried")
        let pending = store.pending(conversationID: "c1").first { $0.clientMessageID == cmid }
        XCTAssertNotNil(pending, "Failed message should remain in the store")
        if case .failed(_, let retriable) = pending?.state {
            XCTAssertFalse(retriable, "4xx failure must be marked retriable: false")
        } else {
            XCTFail("Expected .failed state, got \(String(describing: pending?.state))")
        }
    }

    // MARK: - Task 2.8: Cancel V1

    func test_cancel_removesEnqueuedMessage() {
        let mock = MockAPIClient()
        // Don't configure sendStub — we cancel before it fires.
        // We need a stub to avoid fatalError if send races with cancel;
        // use a blocker to ensure the send hasn't started.
        let blocker = AsyncBlocker()
        mock.sendStub = { conv, body, _, _, cmid in
            await blocker.wait()
            return Message.testFixture(id: "srv", clientMessageID: cmid, conversationID: conv, content: body)
        }

        let store = OutboxStore(api: mock, retryClock: ImmediateClock())
        let cmid = "cmid-cancel-enq"
        store.enqueue(PendingMessage(
            clientMessageID: cmid,
            conversationID: "c1",
            content: "x",
            replyToID: nil,
            attachments: [],
            attempts: 0,
            createdAt: Date(),
            state: .enqueued
        ))

        store.cancel(clientMessageID: cmid)
        XCTAssertNil(
            store.pending(conversationID: "c1").first { $0.clientMessageID == cmid },
            "cancel() must remove the message from the queue when it is enqueued"
        )

        // Release the blocker so the Task doesn't leak / hang.
        blocker.release()
    }

    func test_cancel_isNoOp_whenStateIsUploadingOrSending() async throws {
        let mock = MockAPIClient()
        let cmid = "cmid-cancel-sending"
        let blocker = AsyncBlocker()
        mock.sendStub = { conv, body, _, _, msgCmid in
            await blocker.wait()
            return Message.testFixture(id: "srv", clientMessageID: msgCmid, conversationID: conv, content: body)
        }

        let store = OutboxStore(api: mock, retryClock: ImmediateClock())
        store.enqueue(PendingMessage(
            clientMessageID: cmid,
            conversationID: "c1",
            content: "x",
            replyToID: nil,
            attachments: [],
            attempts: 0,
            createdAt: Date(),
            state: .enqueued
        ))

        // Wait until the FSM has entered .sending (stub is blocking the network call).
        try await waitForState(store: store, cmid: cmid, conv: "c1", state: .sending, timeout: 2.0)

        store.cancel(clientMessageID: cmid)

        let stillThere = store.pending(conversationID: "c1").first { $0.clientMessageID == cmid }
        XCTAssertNotNil(stillThere, "cancel() must be a no-op while the message is in-flight (.sending)")

        // Unblock the stub so the send completes and the test finishes cleanly.
        blocker.release()
        try await store.waitUntilIdle(timeout: 2.0)
    }
}
