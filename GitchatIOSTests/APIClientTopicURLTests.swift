import XCTest
// Module name is `Gitchat` (PRODUCT_NAME in project.yml), not `GitchatIOS`.
@testable import Gitchat

final class APIClientTopicURLTests: XCTestCase {

    func testListPath() {
        XCTAssertEqual(TopicEndpoints.list(parentId: "p"),
                       "messages/conversations/p/topics")
    }

    func testCreatePath() {
        XCTAssertEqual(TopicEndpoints.create(parentId: "p"),
                       "messages/conversations/p/topics")
    }

    func testArchivePath() {
        XCTAssertEqual(TopicEndpoints.archive(parentId: "p", topicId: "t"),
                       "messages/conversations/p/topics/t/archive")
    }

    func testPinPath() {
        XCTAssertEqual(TopicEndpoints.pin(parentId: "p", topicId: "t"),
                       "messages/conversations/p/topics/t/pin")
    }

    func testSendMessagePath() {
        XCTAssertEqual(TopicEndpoints.sendMessage(parentId: "p", topicId: "t"),
                       "messages/conversations/p/topics/t/messages")
    }

    func testListQueryItemsRespectFlags() {
        let q = TopicEndpoints.listQuery(includeArchived: true,
                                          pinnedOnly: false, limit: 50)
        // includeArchived=true → present
        XCTAssertEqual(q.first(where: { $0.name == "includeArchived" })?.value, "true")
        // pinnedOnly=false → omitted (BE bug workaround)
        XCTAssertNil(q.first(where: { $0.name == "pinnedOnly" }))
        XCTAssertEqual(q.first(where: { $0.name == "limit" })?.value, "50")
    }

    /// Regression test for BE bug — class-transformer's
    /// `@Type(() => Boolean)` parses `"false"` as `true`. iOS must omit
    /// false flags from the query string entirely.
    func testFalseFlagsOmittedFromQuery() {
        let q = TopicEndpoints.listQuery(includeArchived: false,
                                          pinnedOnly: false, limit: 100)
        XCTAssertNil(q.first(where: { $0.name == "includeArchived" }))
        XCTAssertNil(q.first(where: { $0.name == "pinnedOnly" }))
        XCTAssertEqual(q.first(where: { $0.name == "limit" })?.value, "100")
        XCTAssertEqual(q.count, 1)
    }
}
