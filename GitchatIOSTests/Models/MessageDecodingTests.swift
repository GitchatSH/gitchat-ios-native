import XCTest
@testable import Gitchat

final class MessageDecodingTests: XCTestCase {
    func test_decodesMessage_withClientMessageId() throws {
        let json = #"""
        {
          "id": "srv-1",
          "client_message_id": "cmid-uuid-1",
          "conversation_id": "conv-1",
          "sender": "alice",
          "content": "hi",
          "created_at": "2026-04-28T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertEqual(msg.client_message_id, "cmid-uuid-1")
    }

    func test_decodesMessage_withoutClientMessageId_legacyPayload() throws {
        let json = #"""
        {
          "id": "srv-2",
          "conversation_id": "conv-1",
          "sender": "alice",
          "content": "hi",
          "created_at": "2026-04-28T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertNil(msg.client_message_id)
    }

    func test_decodesMessage_withNullClientMessageId() throws {
        let json = #"""
        {
          "id": "srv-3",
          "client_message_id": null,
          "conversation_id": "conv-1",
          "sender": "alice",
          "content": "hi",
          "created_at": "2026-04-28T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertNil(msg.client_message_id)
    }
}
