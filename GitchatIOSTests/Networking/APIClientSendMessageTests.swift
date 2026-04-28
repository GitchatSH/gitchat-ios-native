import XCTest
@testable import Gitchat

final class APIClientSendMessageTests: XCTestCase {

    /// Build an APIClient that routes through StubURLProtocol by injecting
    /// a session whose configuration includes the stub class.
    private func makeStubClient() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        return APIClient(session: session)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func test_sendMessage_includes_clientMessageID_inBody() async throws {
        StubURLProtocol.responseBody = Data(#"""
        {"data":{"id":"srv-1","client_message_id":"cmid-test-1","conversation_id":"c1","sender":"alice","content":"hi","created_at":"2026-04-28T10:00:00Z"}}
        """#.utf8)

        let client = makeStubClient()
        _ = try? await client.sendMessage(
            conversationId: "c1",
            body: "hi",
            replyTo: nil,
            attachmentURL: nil,
            attachmentURLs: nil,
            clientMessageID: "cmid-test-1"
        )

        let bodyJSON = try XCTUnwrap(StubURLProtocol.lastRequestBody as? [String: Any])
        XCTAssertEqual(bodyJSON["client_message_id"] as? String, "cmid-test-1")
    }

    func test_sendMessage_omits_clientMessageID_whenNil() async throws {
        StubURLProtocol.responseBody = Data(#"""
        {"data":{"id":"srv-2","conversation_id":"c1","sender":"alice","content":"hi","created_at":"2026-04-28T10:00:00Z"}}
        """#.utf8)

        let client = makeStubClient()
        _ = try? await client.sendMessage(
            conversationId: "c1",
            body: "hi",
            replyTo: nil,
            attachmentURL: nil,
            attachmentURLs: nil,
            clientMessageID: nil
        )

        let bodyJSON = try XCTUnwrap(StubURLProtocol.lastRequestBody as? [String: Any])
        XCTAssertNil(bodyJSON["client_message_id"])
    }
}
