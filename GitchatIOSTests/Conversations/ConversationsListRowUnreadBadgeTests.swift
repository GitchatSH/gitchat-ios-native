import XCTest
import SwiftUI
@testable import Gitchat

/// Smoke tests for `ConversationRow.accessibilityRowLabel`. The badge
/// itself is a SwiftUI view (not directly snapshot-tested here); the
/// a11y label is the testable contract that mirrors what VoiceOver
/// users hear when the row's unread count changes — which is the
/// observable end-result of the topic-bubble fix.
@MainActor
final class ConversationsListRowUnreadBadgeTests: XCTestCase {

    func test_rowAccessibilityLabel_includesPluralUnreadCount() {
        let team = Conversation.fixtureTeam(id: "team-1", unreadCount: 5)
        let row = ConversationRow(conversation: team, isLocallyRead: false)
        XCTAssertTrue(
            row.accessibilityRowLabel.contains("5 unread messages"),
            "Row a11y label must include '5 unread messages' when unreadCount = 5. Got: \(row.accessibilityRowLabel)"
        )
    }

    func test_rowAccessibilityLabel_singularForOne() {
        let team = Conversation.fixtureTeam(id: "team-1", unreadCount: 1)
        let row = ConversationRow(conversation: team, isLocallyRead: false)
        XCTAssertTrue(
            row.accessibilityRowLabel.contains("1 unread message"),
            "Got: \(row.accessibilityRowLabel)"
        )
        XCTAssertFalse(row.accessibilityRowLabel.contains("1 unread messages"))
    }

    func test_locallyRead_suppressesUnreadInLabel() {
        let team = Conversation.fixtureTeam(id: "team-1", unreadCount: 5)
        let row = ConversationRow(conversation: team, isLocallyRead: true)
        XCTAssertFalse(
            row.accessibilityRowLabel.contains("unread"),
            "isLocallyRead=true must hide the unread phrase from a11y. Got: \(row.accessibilityRowLabel)"
        )
    }

    func test_zeroUnread_omitsUnreadFromLabel() {
        let team = Conversation.fixtureTeam(id: "team-1", unreadCount: 0)
        let row = ConversationRow(conversation: team, isLocallyRead: false)
        XCTAssertFalse(row.accessibilityRowLabel.contains("unread"))
    }
}
