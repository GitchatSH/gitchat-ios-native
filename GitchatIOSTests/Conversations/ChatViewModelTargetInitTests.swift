import XCTest
@testable import Gitchat

@MainActor
final class ChatViewModelTargetInitTests: XCTestCase {

    /// Regression: when ChatDetailView is constructed with `initialTopic`,
    /// the ChatViewModel must be initialized with `.topic(...)` target —
    /// not `.conversation(parent)`.
    ///
    /// Why this exists as a unit test: ChatDetailView is a SwiftUI View
    /// whose init wraps a `StateObject(wrappedValue: ChatViewModel(...))`.
    /// We can't easily reach into the View's wrapped state from XCTest, so
    /// instead this test pins the contract that the init relies on:
    /// `ChatViewModel(target: .topic(...))` exposes `.target.conversationId`
    /// equal to the topic id, and the legacy `vm.conversation` accessor
    /// returns the parent for compatibility with old call sites.
    ///
    /// If this contract holds, ChatDetailView's `initialTopic` init can be
    /// trusted to wire socket handlers (which match against
    /// `vm.target.conversationId`) to the topic surface.
    func test_topicTargetInit_targetIdIsTopic_conversationIsParent() {
        let parent = Conversation.fixture(id: "parent-conv")
        let topic = Topic.fixture(id: "topic-7", parentId: parent.id)
        let store = OutboxStore(api: MockAPIClient())

        let vm = ChatViewModel(target: .topic(topic, parent: parent), outbox: store)

        XCTAssertEqual(vm.target.conversationId, topic.id,
                       "vm.target.conversationId must be the topic id so socket handlers route topic messages here")
        XCTAssertEqual(vm.conversation.id, parent.id,
                       "vm.conversation legacy accessor must return the parent so existing call sites keep working")
    }

    /// Counter-test: convenience init with a Conversation only must produce
    /// a `.conversation` target — never a `.topic` target.
    func test_conversationTargetInit_targetIdIsConversation() {
        let conv = Conversation.fixture(id: "dm-1")
        let store = OutboxStore(api: MockAPIClient())

        let vm = ChatViewModel(conversation: conv, outbox: store)

        XCTAssertEqual(vm.target.conversationId, conv.id)
        XCTAssertEqual(vm.conversation.id, conv.id)
    }
}
