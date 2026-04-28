import XCTest

// Module name is `Gitchat` (PRODUCT_NAME in project.yml), not `GitchatIOS`.
// Future test files in this target should use the same import.
@testable import Gitchat

final class ChatTargetTests: XCTestCase {
    private let conv = Conversation.fixture(id: "conv-1")

    func testConversationCaseExposesItsId() {
        let t: ChatTarget = .conversation(conv)
        XCTAssertEqual(t.conversationId, "conv-1")
        XCTAssertNil(t.parentConversationId)
    }
}

// Conversation.fixture is defined in Fixtures.swift (shared across test files).
