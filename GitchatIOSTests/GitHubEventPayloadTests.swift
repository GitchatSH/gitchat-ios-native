import XCTest
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
