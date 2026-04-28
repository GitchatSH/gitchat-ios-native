import XCTest
// Module name is `Gitchat` (PRODUCT_NAME in project.yml), not `GitchatIOS`.
@testable import Gitchat

final class TopicDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> Topic {
        try JSONDecoder().decode(Topic.self, from: Data(json.utf8))
    }

    /// Full BE TopicResponseDto payload — camelCase, matches
    /// `gitchat-webapp/backend/src/modules/messages/dto/topic-response.dto.ts`.
    func testFullPayloadDecodes() throws {
        let json = """
        {
          "id": "topic-1", "parentConversationId": "conv-1",
          "name": "Bug Reports", "iconEmoji": "🐛", "colorToken": "red",
          "isGeneral": false, "pinOrder": 1,
          "archivedAt": null,
          "lastMessageAt": "2026-04-28T10:00:00Z",
          "lastMessageText": "broken on iPad",
          "lastSenderLogin": "alice",
          "unreadCount": 3, "unreadMentionsCount": 1, "unreadReactionsCount": 0,
          "createdBy": "alice", "createdAt": "2026-04-20T08:00:00Z"
        }
        """
        let t = try decode(json)
        XCTAssertEqual(t.id, "topic-1")
        XCTAssertEqual(t.parent_conversation_id, "conv-1")
        XCTAssertEqual(t.color_token, "red")
        XCTAssertEqual(t.last_message_preview, "broken on iPad")    // lastMessageText → last_message_preview
        XCTAssertTrue(t.isPinned)
        XCTAssertFalse(t.isArchived)
        XCTAssertTrue(t.hasMention)
        XCTAssertFalse(t.hasReaction)
        XCTAssertEqual(t.displayEmoji, "🐛")
    }

    func testGeneralTopicDecodes() throws {
        let t = try decode("""
        { "id":"g","parentConversationId":"p","name":"General","isGeneral":true,
          "unreadCount":0,"unreadMentionsCount":0,"unreadReactionsCount":0,
          "createdBy":"alice","createdAt":"2026-04-20T08:00:00Z" }
        """)
        XCTAssertTrue(t.is_general)
        XCTAssertNil(t.icon_emoji)
        XCTAssertEqual(t.displayEmoji, "💬")
        XCTAssertNil(t.pin_order)
        XCTAssertFalse(t.isPinned)
    }

    func testArchivedTopicDecodes() throws {
        let t = try decode("""
        { "id":"a","parentConversationId":"p","name":"Old","isGeneral":false,
          "archivedAt":"2026-04-25T10:00:00Z",
          "unreadCount":0,"unreadMentionsCount":0,"unreadReactionsCount":0,
          "createdBy":"x","createdAt":"2026-04-01T00:00:00Z" }
        """)
        XCTAssertTrue(t.isArchived)
    }

    /// Verbatim JSON copied from a real local-BE response that the user
    /// reported on 2026-04-28. This is the EXACT shape `topic_chips`
    /// embeds in the conversation list — used as a regression test
    /// against the camelCase mismatch bug. If this fails to decode all
    /// fields the iOS topic UI breaks on real BE.
    func testRealBETopicChipDecodes() throws {
        let json = """
        {
          "id":"9119053d-3f9c-4daa-9c1c-56d86d2a1b6c",
          "name":"Debug",
          "iconEmoji":"🚀",
          "colorToken":"blue",
          "lastMessageAt":"2026-04-28T10:42:11.960Z",
          "lastMessageText":"Alo",
          "lastSenderLogin":"quangvuong1008",
          "unreadCount":0
        }
        """
        let t = try decode(json)
        XCTAssertEqual(t.id, "9119053d-3f9c-4daa-9c1c-56d86d2a1b6c")
        XCTAssertEqual(t.name, "Debug")
        XCTAssertEqual(t.icon_emoji, "🚀")
        XCTAssertEqual(t.displayEmoji, "🚀")
        XCTAssertEqual(t.color_token, "blue")
        XCTAssertEqual(t.last_message_at, "2026-04-28T10:42:11.960Z")
        XCTAssertEqual(t.last_message_preview, "Alo")
        XCTAssertEqual(t.last_sender_login, "quangvuong1008")
        XCTAssertEqual(t.unread_count, 0)
        // Fields absent from chip embed: defaults from custom init
        XCTAssertEqual(t.parent_conversation_id, "")
        XCTAssertFalse(t.is_general)
        XCTAssertNil(t.pin_order)
    }

    /// Exact list response shape from BE listTopics endpoint.
    /// NestJS TransformInterceptor wraps payload as { data: [...] }.
    /// APIClient.request unwraps via APIEnvelope. This test verifies
    /// the array shape decodes correctly when given a raw list payload.
    func testRealBETopicListDecodes() throws {
        let json = """
        [
          {"id":"9119053d-3f9c-4daa-9c1c-56d86d2a1b6c","parentConversationId":"4d280b87-b9ba-4f0d-823a-434b5d7d473d","name":"Debug","iconEmoji":"🚀","colorToken":"blue","isGeneral":false,"pinOrder":null,"closedAt":null,"archivedAt":null,"hiddenFromDefault":false,"createdBy":"quangvuong1008","createdAt":"2026-04-28T10:00:00.000Z","lastMessageAt":"2026-04-28T10:42:11.960Z","lastMessageText":"Alo","lastSenderLogin":"quangvuong1008","unreadCount":0,"unreadMentionsCount":0,"unreadReactionsCount":0},
          {"id":"0a94ddec-1297-4006-9e06-04d0128410d6","parentConversationId":"4d280b87-b9ba-4f0d-823a-434b5d7d473d","name":"General","iconEmoji":"💬","colorToken":"blue","isGeneral":true,"pinOrder":null,"closedAt":null,"archivedAt":null,"hiddenFromDefault":false,"createdBy":"quangvuong1008","createdAt":"2026-04-28T10:00:00.000Z","lastMessageAt":"2026-04-28T10:41:52.923Z","lastMessageText":"Alo","lastSenderLogin":"quangvuong1008","unreadCount":0,"unreadMentionsCount":0,"unreadReactionsCount":0}
        ]
        """
        let topics = try JSONDecoder().decode([Topic].self, from: Data(json.utf8))
        XCTAssertEqual(topics.count, 2)
        XCTAssertEqual(topics[0].name, "Debug")
        XCTAssertFalse(topics[0].is_general)
        XCTAssertEqual(topics[1].name, "General")
        XCTAssertTrue(topics[1].is_general)
        XCTAssertEqual(topics[1].displayEmoji, "💬")
    }

    func testChatTargetTopicCase() {
        let conv = Conversation.fixture(id: "conv-1")
        let topic = Topic.fixture(id: "topic-1", parentId: "conv-1")
        let t: ChatTarget = .topic(topic, parent: conv)
        XCTAssertEqual(t.conversationId, "topic-1")
        XCTAssertEqual(t.parentConversationId, "conv-1")
    }
}
