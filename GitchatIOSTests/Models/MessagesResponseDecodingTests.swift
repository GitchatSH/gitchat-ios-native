import XCTest
@testable import Gitchat

final class MessagesResponseDecodingTests: XCTestCase {

    /// Regression: BE renamed the per-user read cursors field on the GET
    /// messages response from `readCursors` → `readReceipts` in commit
    /// 13b006f (2026-04-17). iOS silently decoded nil into the old field
    /// for ~3 weeks, so SeenBySheet showed empty viewer lists and read
    /// ticks never advanced. This test pins the new wire shape.
    func test_decodesReadReceipts_groupShape_withProfileFields() throws {
        let json = #"""
        {
          "messages": [],
          "nextCursor": null,
          "previousCursor": null,
          "otherReadAt": "2026-05-09T12:00:00.000Z",
          "readReceipts": [
            {
              "login": "bob",
              "name": "Bob",
              "avatar_url": "https://github.com/bob.png",
              "readAt": "2026-05-09T12:00:00.000Z"
            },
            {
              "login": "carol",
              "name": "Carol",
              "avatar_url": "https://github.com/carol.png",
              "readAt": "2026-05-09T12:01:00.000Z"
            }
          ]
        }
        """#.data(using: .utf8)!

        let resp = try JSONDecoder().decode(MessagesResponse.self, from: json)
        XCTAssertEqual(resp.otherReadAt, "2026-05-09T12:00:00.000Z")
        XCTAssertEqual(resp.readReceipts?.count, 2)
        XCTAssertEqual(resp.readReceipts?.first?.login, "bob")
        XCTAssertEqual(resp.readReceipts?.first?.readAt, "2026-05-09T12:00:00.000Z")
    }

    /// DM shape: BE may omit readReceipts entirely (only otherReadAt).
    func test_decodesReadReceipts_dmShape_omittedField() throws {
        let json = #"""
        {
          "messages": [],
          "nextCursor": null,
          "previousCursor": null,
          "otherReadAt": "2026-05-09T12:00:00.000Z"
        }
        """#.data(using: .utf8)!

        let resp = try JSONDecoder().decode(MessagesResponse.self, from: json)
        XCTAssertEqual(resp.otherReadAt, "2026-05-09T12:00:00.000Z")
        XCTAssertNil(resp.readReceipts)
    }

    /// Guard against a regression to the old field name. If BE accidentally
    /// reverts to `readCursors`, this test should still pass (unknown key
    /// is ignored), but the assertion that readReceipts is nil flags the
    /// data loss explicitly.
    func test_oldFieldNameIsIgnored_signallingDataLoss() throws {
        let json = #"""
        {
          "messages": [],
          "nextCursor": null,
          "previousCursor": null,
          "otherReadAt": null,
          "readCursors": [
            { "login": "bob", "readAt": "2026-05-09T12:00:00.000Z" }
          ]
        }
        """#.data(using: .utf8)!

        let resp = try JSONDecoder().decode(MessagesResponse.self, from: json)
        XCTAssertNil(resp.readReceipts, "Old field name must not silently populate the new one — that was the original bug")
    }
}
