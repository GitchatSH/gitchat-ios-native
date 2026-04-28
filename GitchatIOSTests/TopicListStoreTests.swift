import XCTest
// Module name is `Gitchat` (PRODUCT_NAME in project.yml), not `GitchatIOS`.
@testable import Gitchat

@MainActor
final class TopicListStoreTests: XCTestCase {

    func testAppendInsertsTopicForParent() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t1", parentId: "p1"), parentId: "p1")
        XCTAssertEqual(store.topics(forParent: "p1").count, 1)
    }

    func testSortPinnedBeforeUnpinned() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "u1", parentId: "p"), parentId: "p")
        store.append(Topic.fixture(id: "p2", parentId: "p", pinOrder: 2), parentId: "p")
        store.append(Topic.fixture(id: "p1", parentId: "p", pinOrder: 1), parentId: "p")

        let order = store.topics(forParent: "p").map(\.id)
        XCTAssertEqual(order, ["p1", "p2", "u1"])  // pin asc, then unpinned
    }

    func testArchiveRemovesFromList() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t1", parentId: "p"), parentId: "p")
        store.archive(topicId: "t1", parentId: "p")
        XCTAssertTrue(store.topics(forParent: "p").isEmpty)
    }

    func testApplyEventCreated() {
        let store = TopicListStore()
        let t = Topic.fixture(id: "t1", parentId: "p")
        store.applyEvent(.created(parentId: "p", topic: t))
        XCTAssertEqual(store.topics(forParent: "p").count, 1)
    }

    func testApplyEventPinnedReorders() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "a", parentId: "p"), parentId: "p")
        store.append(Topic.fixture(id: "b", parentId: "p"), parentId: "p")
        store.applyEvent(.pinned(parentId: "p", topicId: "b", pinOrder: 1))
        XCTAssertEqual(store.topics(forParent: "p").map(\.id), ["b", "a"])
    }

    func testBumpUnreadIncrementsCount() {
        let store = TopicListStore()
        store.append(Topic.fixture(id: "t", parentId: "p", unread: 2), parentId: "p")
        store.bumpUnread(topicId: "t", parentId: "p", by: 1)
        XCTAssertEqual(store.topics(forParent: "p").first?.unread_count, 3)
    }

    func testLRUEvictsOldestParent() {
        let store = TopicListStore(maxParents: 2)
        store.append(Topic.fixture(id: "x", parentId: "p1"), parentId: "p1")
        store.append(Topic.fixture(id: "x", parentId: "p2"), parentId: "p2")
        store.append(Topic.fixture(id: "x", parentId: "p3"), parentId: "p3")  // evicts p1
        XCTAssertTrue(store.topics(forParent: "p1").isEmpty)
        XCTAssertEqual(store.topics(forParent: "p2").count, 1)
        XCTAssertEqual(store.topics(forParent: "p3").count, 1)
    }
}
