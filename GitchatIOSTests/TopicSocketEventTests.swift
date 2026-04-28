import XCTest
// Module name is `Gitchat` (PRODUCT_NAME in project.yml), not `GitchatIOS`.
@testable import Gitchat

final class TopicSocketEventTests: XCTestCase {

    private let topicJSON: [String: Any] = [
        "id": "t1", "parent_conversation_id": "p1",
        "name": "Bugs", "icon_emoji": "🐛", "color_token": "red",
        "is_general": false, "pin_order": NSNull(),
        "archived_at": NSNull(),
        "last_message_at": NSNull(), "last_message_preview": NSNull(),
        "last_sender_login": NSNull(),
        "unread_count": 0, "unread_mentions_count": 0, "unread_reactions_count": 0,
        "created_by": "alice", "created_at": "2026-04-20T08:00:00Z"
    ]

    func testCreatedEventDecodes() throws {
        let payload: [String: Any] = ["parentId": "p1", "topic": topicJSON]
        let evt = try XCTUnwrap(TopicSocketEvent.from(eventName: "topic:created", payload: payload))
        guard case .created(let parentId, let topic) = evt else { return XCTFail("wrong case") }
        XCTAssertEqual(parentId, "p1")
        XCTAssertEqual(topic.id, "t1")
    }

    func testPinnedEventDecodes() throws {
        let payload: [String: Any] = ["parentId":"p1","topicId":"t1","pinOrder":2]
        let evt = try XCTUnwrap(TopicSocketEvent.from(eventName: "topic:pinned", payload: payload))
        guard case .pinned(_, _, let order) = evt else { return XCTFail("wrong case") }
        XCTAssertEqual(order, 2)
    }

    func testArchivedEventDecodes() throws {
        let payload: [String: Any] = ["parentId":"p1","topicId":"t1"]
        let evt = try XCTUnwrap(TopicSocketEvent.from(eventName: "topic:archived", payload: payload))
        if case .archived(let p, let t) = evt {
            XCTAssertEqual(p, "p1"); XCTAssertEqual(t, "t1")
        } else { XCTFail("wrong case") }
    }

    func testUnknownEventReturnsNil() {
        XCTAssertNil(TopicSocketEvent.from(eventName: "topic:closed", payload: [:]))
    }
}
