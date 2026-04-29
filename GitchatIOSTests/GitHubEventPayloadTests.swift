import XCTest
import SwiftUI
@testable import Gitchat

final class GitHubEventPayloadTests: XCTestCase {

    private func decode(_ json: String) throws -> GitHubEventPayload {
        try JSONDecoder().decode(GitHubEventPayload.self, from: Data(json.utf8))
    }

    func testFullPayloadDecodes() throws {
        let json = """
        {"eventType":"issue_opened","title":"[Bug] Wave fires toast",\
        "url":"https://github.com/org/repo/issues/201","actor":"alice",\
        "githubEventId":"8815949909"}
        """
        let p = try decode(json)
        XCTAssertEqual(p.eventType, "issue_opened")
        XCTAssertEqual(p.title, "[Bug] Wave fires toast")
        XCTAssertEqual(p.url, "https://github.com/org/repo/issues/201")
        XCTAssertEqual(p.actor, "alice")
        XCTAssertEqual(p.githubEventId, "8815949909")
    }

    func testMissingOptionalsDecodes() throws {
        let json = """
        {"eventType":"issue_opened","title":"x"}
        """
        let p = try decode(json)
        XCTAssertNil(p.url)
        XCTAssertNil(p.actor)
        XCTAssertNil(p.githubEventId)
    }

    func testMissingRequiredFails() {
        let json = """
        {"title":"no event type"}
        """
        XCTAssertThrowsError(try decode(json))
    }
}

final class GitHubEventStyleTests: XCTestCase {

    func testIssueOpenedHasDetailStyle() {
        let s = GitHubEventStyle.from(eventType: "issue_opened")
        XCTAssertEqual(s.icon, "circle.dotted")
        XCTAssertEqual(s.verb, "opened issue")
        // Color is .orange — compare via description since SwiftUI Color
        // doesn't expose a direct equality channel.
        XCTAssertEqual(String(describing: s.color), String(describing: Color.orange))
    }

    func testUnknownEventUsesGenericFallback() {
        let s = GitHubEventStyle.from(eventType: "pr_opened")
        XCTAssertEqual(s.icon, "dot.radiowaves.left.and.right")
        XCTAssertEqual(s.verb, "opened pr")
        XCTAssertEqual(String(describing: s.color), String(describing: Color.secondary))
    }

    func testHumanizeSwapsNounAndVerb() {
        XCTAssertEqual(GitHubEventStyle.humanize("issue_closed"), "closed issue")
        XCTAssertEqual(GitHubEventStyle.humanize("pr_merged"), "merged pr")
    }

    func testHumanizeFallsBackForNoUnderscore() {
        XCTAssertEqual(GitHubEventStyle.humanize("push"), "push")
    }

    func testHumanizeHandlesMultipleUnderscores() {
        // "release_published" → object="release", verb="published"
        XCTAssertEqual(GitHubEventStyle.humanize("release_published"), "published release")
    }
}

final class GitHubEventDetectionTests: XCTestCase {

    func testPlainTextReturnsNil() {
        XCTAssertNil(GitHubEventPayload.tryParse("hello world"))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(GitHubEventPayload.tryParse(""))
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(GitHubEventPayload.tryParse("{not valid json"))
    }

    func testValidPayloadReturnsStruct() {
        let raw = #"{"eventType":"issue_opened","title":"Hi","url":"https://x","actor":"a"}"#
        let p = GitHubEventPayload.tryParse(raw)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.title, "Hi")
    }

    func testEmptyTitleReturnsNil() {
        let raw = #"{"eventType":"issue_opened","title":"","url":"https://x","actor":"a"}"#
        XCTAssertNil(GitHubEventPayload.tryParse(raw))
    }

    func testEmptyEventTypeReturnsNil() {
        let raw = #"{"eventType":"","title":"hi","url":"https://x","actor":"a"}"#
        XCTAssertNil(GitHubEventPayload.tryParse(raw))
    }

    func testLeadingWhitespaceStillParses() {
        let raw = "   \n" + #"{"eventType":"issue_opened","title":"Hi"}"#
        XCTAssertNotNil(GitHubEventPayload.tryParse(raw))
    }

    func testTextStartingWithBraceButNotJSONReturnsNil() {
        // Edge: someone literally typed "{hello}" as a chat message.
        XCTAssertNil(GitHubEventPayload.tryParse("{hello}"))
    }
}
