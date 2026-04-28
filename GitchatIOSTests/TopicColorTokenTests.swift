import XCTest
// Module name is `Gitchat` (PRODUCT_NAME in project.yml), not `GitchatIOS`.
@testable import Gitchat

final class TopicColorTokenTests: XCTestCase {
    func testKnownTokens() {
        XCTAssertEqual(TopicColorToken.resolve("red"), .red)
        XCTAssertEqual(TopicColorToken.resolve("BLUE"), .blue)        // case-insensitive
        XCTAssertEqual(TopicColorToken.resolve("orange"), .orange)
    }

    func testNilOrUnknownReturnsBlue() {
        XCTAssertEqual(TopicColorToken.resolve(nil), .blue)
        XCTAssertEqual(TopicColorToken.resolve("magenta"), .blue)     // not in BE enum
    }

    func testAllCasesCovered() {
        XCTAssertEqual(TopicColorToken.allCases.count, 8)
    }
}
