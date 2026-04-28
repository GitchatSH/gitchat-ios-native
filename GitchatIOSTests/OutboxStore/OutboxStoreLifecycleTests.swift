import XCTest
@testable import Gitchat

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
}
