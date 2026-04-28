import XCTest
// Module name is `Gitchat` (PRODUCT_NAME in project.yml), not `GitchatIOS`.
@testable import Gitchat

@MainActor
final class ChatViewModelEndpointTests: XCTestCase {
    func testConversationSendEndpoint() {
        let vm = ChatViewModel(target: .conversation(.fixture(id: "c")))
        XCTAssertEqual(vm.testHook_sendEndpoint, "messages/conversations/c")
    }

    func testTopicSendEndpoint() {
        let parent = Conversation.fixture(id: "p")
        let topic = Topic.fixture(id: "t", parentId: "p")
        let vm = ChatViewModel(target: .topic(topic, parent: parent))
        XCTAssertEqual(vm.testHook_sendEndpoint,
                       "messages/conversations/p/topics/t/messages")
    }
}
