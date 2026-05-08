import XCTest
@testable import Gitchat

/// Regression coverage for the topic-send path. Image-only sends to a
/// topic must include `attachments` in the POST body — otherwise BE
/// rejects with 400 "Message must have body text or attachments"
/// (messages.service.ts validation).
@MainActor
final class APIClientTopicSendMessageTests: XCTestCase {

    private func makeStubClient() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        return APIClient(session: session)
    }

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        AuthStore.shared._testPrimeAuth(token: "test-token")
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        AuthStore.shared._testClearAuth()
        try await super.tearDown()
    }

    func test_topicSendMessage_includesAttachments_inBody() async throws {
        StubURLProtocol.responseBody = Data(#"""
        {"data":{"id":"srv-1","client_message_id":"cmid-1","conversation_id":"t1","sender":"alice","content":"","created_at":"2026-05-08T10:00:00Z"}}
        """#.utf8)

        let client = makeStubClient()
        let attachment: [String: Any] = [
            "type": "image",
            "url": "https://cdn.example/img.jpg",
            "storage_path": "uploads/img.jpg",
            "mime_type": "image/jpeg",
            "size_bytes": 12345,
            "width": 1024,
            "height": 768
        ]

        _ = try? await client.sendMessage(
            at: TopicEndpoints.sendMessage(parentId: "p1", topicId: "t1"),
            body: "",
            attachments: [attachment],
            replyToID: nil,
            clientMessageID: "cmid-1"
        )

        let bodyJSON = try XCTUnwrap(StubURLProtocol.lastRequestBody as? [String: Any])
        XCTAssertEqual(bodyJSON["body"] as? String, "")
        XCTAssertEqual(bodyJSON["client_message_id"] as? String, "cmid-1")
        let atts = try XCTUnwrap(bodyJSON["attachments"] as? [[String: Any]])
        XCTAssertEqual(atts.count, 1)
        XCTAssertEqual(atts[0]["type"] as? String, "image")
        XCTAssertEqual(atts[0]["url"] as? String, "https://cdn.example/img.jpg")
        XCTAssertEqual(atts[0]["storage_path"] as? String, "uploads/img.jpg")
        XCTAssertEqual(atts[0]["width"] as? Int, 1024)
    }

    func test_topicSendMessage_omitsAttachments_whenEmpty() async throws {
        StubURLProtocol.responseBody = Data(#"""
        {"data":{"id":"srv-2","conversation_id":"t1","sender":"alice","content":"hi","created_at":"2026-05-08T10:00:00Z"}}
        """#.utf8)

        let client = makeStubClient()
        _ = try? await client.sendMessage(
            at: TopicEndpoints.sendMessage(parentId: "p1", topicId: "t1"),
            body: "hi",
            attachments: [],
            replyToID: nil,
            clientMessageID: nil
        )

        let bodyJSON = try XCTUnwrap(StubURLProtocol.lastRequestBody as? [String: Any])
        XCTAssertEqual(bodyJSON["body"] as? String, "hi")
        XCTAssertNil(bodyJSON["attachments"])
        XCTAssertNil(bodyJSON["client_message_id"])
    }

    func test_topicSendMessage_skipsAttachments_missingURL() async throws {
        StubURLProtocol.responseBody = Data(#"""
        {"data":{"id":"srv-3","conversation_id":"t1","sender":"alice","content":"","created_at":"2026-05-08T10:00:00Z"}}
        """#.utf8)

        let client = makeStubClient()
        let valid: [String: Any] = ["type": "image", "url": "https://cdn.example/a.jpg"]
        let invalid: [String: Any] = ["type": "image"] // no url
        _ = try? await client.sendMessage(
            at: TopicEndpoints.sendMessage(parentId: "p1", topicId: "t1"),
            body: "",
            attachments: [invalid, valid],
            replyToID: nil,
            clientMessageID: nil
        )

        let bodyJSON = try XCTUnwrap(StubURLProtocol.lastRequestBody as? [String: Any])
        let atts = try XCTUnwrap(bodyJSON["attachments"] as? [[String: Any]])
        XCTAssertEqual(atts.count, 1, "Invalid attachment (no url) should be filtered out")
        XCTAssertEqual(atts[0]["url"] as? String, "https://cdn.example/a.jpg")
    }
}
