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

    // MARK: - ReplyPreview.first_image_url

    func test_decodesReplyPreview_withFirstImageUrl() throws {
        let json = #"""
        {
          "id": "reply-1",
          "body": null,
          "sender_login": "bob",
          "first_image_url": "https://cdn/photo.jpg"
        }
        """#.data(using: .utf8)!
        let reply = try JSONDecoder().decode(ReplyPreview.self, from: json)
        XCTAssertEqual(reply.first_image_url, "https://cdn/photo.jpg")
    }

    func test_decodesReplyPreview_withoutFirstImageUrl_legacyPayload() throws {
        // Older backend builds don't include the field — must decode to nil,
        // not throw. Lets the client run against pre-PR-#78 environments.
        let json = #"""
        {
          "id": "reply-2",
          "body": "hello",
          "sender_login": "bob"
        }
        """#.data(using: .utf8)!
        let reply = try JSONDecoder().decode(ReplyPreview.self, from: json)
        XCTAssertNil(reply.first_image_url)
    }

    func test_decodesReplyPreview_acceptsCamelCaseFirstImageUrl() throws {
        let json = #"""
        {
          "id": "reply-3",
          "body": null,
          "sender_login": "bob",
          "firstImageUrl": "https://cdn/camel.jpg"
        }
        """#.data(using: .utf8)!
        let reply = try JSONDecoder().decode(ReplyPreview.self, from: json)
        XCTAssertEqual(reply.first_image_url, "https://cdn/camel.jpg")
    }

    func test_decodesMessage_propagatesReplyFirstImageUrl() throws {
        let json = #"""
        {
          "id": "srv-9",
          "conversation_id": "conv-1",
          "sender": "alice",
          "content": "look at this!",
          "created_at": "2026-05-08T10:00:00Z",
          "reply_to_id": "reply-1",
          "reply": {
            "id": "reply-1",
            "body": null,
            "sender_login": "bob",
            "first_image_url": "https://cdn/photo.jpg"
          }
        }
        """#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertEqual(msg.reply?.first_image_url, "https://cdn/photo.jpg")
    }
}
