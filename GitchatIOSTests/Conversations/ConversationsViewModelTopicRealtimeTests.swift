import XCTest
@testable import Gitchat

/// Regression tests for the topic-realtime fix on the outer Chats list.
/// Issue: GitchatSH/gitchat-ios-native#148 — receiver's team row preview
/// didn't update until a slower HTTP refetch round-trip, because
/// `message:sent` for topic messages carries `conversation_id == topic id`
/// (not the parent), so `applyIncomingMessage(_:)` couldn't find the row.
/// The new path uses `topic:message`'s payload `parentId` directly.
@MainActor
final class ConversationsViewModelTopicRealtimeTests: XCTestCase {

    func test_applyIncomingTopicMessage_patchesTeamRowByParentId() {
        let vm = ConversationsViewModel()
        vm.conversations = [makeTeam(
            id: "team-1",
            lastText: "earlier",
            lastAt: "2026-05-12T10:30:00.000Z"
        )]

        let topicMsg = makeMessage(
            content: "hello from topic",
            // BE puts the topic id here for topic messages — proves we are
            // NOT relying on this field to find the team row.
            conversationID: "topic-abc",
            createdAt: "2026-05-12T10:35:00.000Z",
            topicID: "topic-abc"
        )
        vm.applyIncomingTopicMessage(parentId: "team-1", message: topicMsg)

        XCTAssertEqual(vm.conversations.first?.last_message_text, "hello from topic")
        XCTAssertEqual(vm.conversations.first?.last_message_at,
                       "2026-05-12T10:35:00.000Z")
    }

    func test_applyIncomingTopicMessage_ignoresUnknownParent() {
        // Defensive: a topic event from a parent we don't currently list
        // (just-joined, archived, demoted) shouldn't crash or mutate state.
        let vm = ConversationsViewModel()
        let original = makeTeam(
            id: "team-1",
            lastText: "earlier",
            lastAt: "2026-05-12T10:30:00.000Z"
        )
        vm.conversations = [original]

        let msg = makeMessage(
            content: "stranger",
            conversationID: "topic-zzz",
            createdAt: "2026-05-12T10:40:00.000Z",
            topicID: "topic-zzz"
        )
        vm.applyIncomingTopicMessage(parentId: "team-stranger", message: msg)

        XCTAssertEqual(vm.conversations.first?.last_message_text, "earlier")
        XCTAssertEqual(vm.conversations.first?.last_message_at,
                       "2026-05-12T10:30:00.000Z")
    }

    func test_applyIncomingTopicMessage_monotonicGuard_skipsOlder() {
        // Mirror applyIncomingMessage's guard — an out-of-order delivery
        // shouldn't roll the team row back to an older preview.
        let vm = ConversationsViewModel()
        vm.conversations = [makeTeam(
            id: "team-1",
            lastText: "newer",
            lastAt: "2026-05-12T10:35:00.500Z"
        )]

        let older = makeMessage(
            content: "older",
            conversationID: "topic-abc",
            createdAt: "2026-05-12T10:35:00.100Z",
            topicID: "topic-abc"
        )
        vm.applyIncomingTopicMessage(parentId: "team-1", message: older)

        XCTAssertEqual(vm.conversations.first?.last_message_text, "newer")
        XCTAssertEqual(vm.conversations.first?.last_message_at,
                       "2026-05-12T10:35:00.500Z")
    }

    func test_applyIncomingTopicMessage_appliesWhenRowHasNoTimestamp() {
        let vm = ConversationsViewModel()
        vm.conversations = [makeTeam(id: "team-1", lastText: nil, lastAt: nil)]

        let msg = makeMessage(
            content: "first",
            conversationID: "topic-abc",
            createdAt: "2026-05-12T10:35:00.000Z",
            topicID: "topic-abc"
        )
        vm.applyIncomingTopicMessage(parentId: "team-1", message: msg)

        XCTAssertEqual(vm.conversations.first?.last_message_text, "first")
    }

    // MARK: - vm.load() refetch tie-breaker (issue #148 part 2)

    func test_mergeRefetchWithLocal_keepsLocalWhenTimestampsTieAndMessageIdsDiffer() {
        // Repro of the BE-inconsistency case: receiver applied a topic
        // message locally (so local.last_message has the topic msg). BE's
        // refetch then returns the team row with a matching last_message_at
        // (bumped by messages.service.ts:1521-1536) but a STALE structured
        // last_message pointing at an older non-topic root message (because
        // the hydration query at messages.service.ts:750-756 filters by
        // conversation_id = parent_id and misses topic messages). Without
        // the tie-breaker, the cell flickers back to the stale root msg
        // body — exactly the bug the user reported on iOS #148.
        let topicMsg = makeMessage(
            id: "topic-msg-fresh",
            content: "2",
            conversationID: "topic-abc",
            createdAt: "2026-05-12T19:46:00.000Z",
            topicID: "topic-abc"
        )
        let local = makeTeam(
            id: "team-1",
            lastText: "2",
            lastAt: "2026-05-12T19:46:00.000Z",
            lastMessage: topicMsg
        )
        let staleRootMsg = makeMessage(
            id: "root-msg-stale",
            content: "Oki chị confirm nha",
            conversationID: "team-1",
            createdAt: "2026-05-12T19:46:00.000Z",
            topicID: nil
        )
        let remote = makeTeam(
            id: "team-1",
            lastText: "2",
            lastAt: "2026-05-12T19:46:00.000Z",
            lastMessage: staleRootMsg
        )

        let merged = ConversationsViewModel.mergeRefetchWithLocal(
            remote: [remote], local: [local]
        )

        XCTAssertEqual(merged.first?.last_message?.id, "topic-msg-fresh",
                       "local's fresh topic message must win the tie against BE's stale root message")
        XCTAssertEqual(merged.first?.last_message?.content, "2")
    }

    func test_mergeRefetchWithLocal_prefersRemoteWhenTimestampsTieAndMessageIdsMatch() {
        // BE has caught up — same timestamp, same message id. No BE
        // inconsistency. Use remote so other fields (unread, mute, etc.)
        // reflect server state.
        let sameMsg = makeMessage(
            id: "msg-shared",
            content: "hello",
            conversationID: "topic-abc",
            createdAt: "2026-05-12T19:46:00.000Z",
            topicID: "topic-abc"
        )
        let local = makeTeam(id: "team-1", lastText: "hello",
                             lastAt: "2026-05-12T19:46:00.000Z", lastMessage: sameMsg)
        let remote = makeTeam(id: "team-1", lastText: "hello",
                              lastAt: "2026-05-12T19:46:00.000Z", lastMessage: sameMsg,
                              unreadCount: 5)

        let merged = ConversationsViewModel.mergeRefetchWithLocal(
            remote: [remote], local: [local]
        )

        XCTAssertEqual(merged.first?.last_message?.id, "msg-shared")
        XCTAssertEqual(merged.first?.unread_count, 5,
                       "tie + same message id → fully remote, including unread")
    }

    func test_mergeRefetchWithLocal_prefersLocalWhenLocalTimestampStrictlyNewer() {
        // Existing #145/#146 defense — unchanged by the new tie-breaker.
        let localMsg = makeMessage(id: "local-newer", content: "newer",
                                   conversationID: "team-1",
                                   createdAt: "2026-05-12T19:46:00.500Z",
                                   topicID: nil)
        let remoteMsg = makeMessage(id: "remote-older", content: "older",
                                    conversationID: "team-1",
                                    createdAt: "2026-05-12T19:46:00.100Z",
                                    topicID: nil)
        let local = makeTeam(id: "team-1", lastText: "newer",
                             lastAt: "2026-05-12T19:46:00.500Z", lastMessage: localMsg)
        let remote = makeTeam(id: "team-1", lastText: "older",
                              lastAt: "2026-05-12T19:46:00.100Z", lastMessage: remoteMsg)

        let merged = ConversationsViewModel.mergeRefetchWithLocal(
            remote: [remote], local: [local]
        )

        XCTAssertEqual(merged.first?.last_message?.id, "local-newer")
        XCTAssertEqual(merged.first?.last_message_text, "newer")
    }

    func test_mergeRefetchWithLocal_prefersRemoteWhenRemoteStrictlyNewer() {
        let localMsg = makeMessage(id: "local-older", content: "older",
                                   conversationID: "team-1",
                                   createdAt: "2026-05-12T19:46:00.100Z",
                                   topicID: nil)
        let remoteMsg = makeMessage(id: "remote-newer", content: "newer",
                                    conversationID: "team-1",
                                    createdAt: "2026-05-12T19:46:00.500Z",
                                    topicID: nil)
        let local = makeTeam(id: "team-1", lastText: "older",
                             lastAt: "2026-05-12T19:46:00.100Z", lastMessage: localMsg)
        let remote = makeTeam(id: "team-1", lastText: "newer",
                              lastAt: "2026-05-12T19:46:00.500Z", lastMessage: remoteMsg)

        let merged = ConversationsViewModel.mergeRefetchWithLocal(
            remote: [remote], local: [local]
        )

        XCTAssertEqual(merged.first?.last_message?.id, "remote-newer")
    }

    func test_mergeRefetchWithLocal_returnsRemoteWhenNoLocalEntryExists() {
        // Cold-start scenario: BE returned a team row we've never seen.
        // Without a local optimistic apply to compare against, just use BE.
        let remoteMsg = makeMessage(id: "remote-only", content: "hi",
                                    conversationID: "team-1",
                                    createdAt: "2026-05-12T19:46:00.000Z",
                                    topicID: nil)
        let remote = makeTeam(id: "team-1", lastText: "hi",
                              lastAt: "2026-05-12T19:46:00.000Z", lastMessage: remoteMsg)

        let merged = ConversationsViewModel.mergeRefetchWithLocal(
            remote: [remote], local: []
        )

        XCTAssertEqual(merged.first?.last_message?.id, "remote-only")
    }

    // MARK: - applyParentUnreadDelta (topic bubble realtime fix)

    func test_applyParentUnreadDelta_bumpsRowUnread() {
        let vm = ConversationsViewModel()
        vm.conversations = [makeTeam(id: "team-1", lastText: nil, lastAt: nil, unreadCount: 2)]

        vm.applyParentUnreadDelta(parentId: "team-1", delta: 3)

        XCTAssertEqual(vm.conversations.first?.unreadCount, 5)
    }

    func test_applyParentUnreadDelta_clampsAtZero() {
        let vm = ConversationsViewModel()
        vm.conversations = [makeTeam(id: "team-1", lastText: nil, lastAt: nil, unreadCount: 1)]

        vm.applyParentUnreadDelta(parentId: "team-1", delta: -10)

        XCTAssertEqual(vm.conversations.first?.unreadCount, 0)
    }

    func test_applyParentUnreadDelta_unknownParent_isNoOp() {
        let vm = ConversationsViewModel()
        vm.conversations = [makeTeam(id: "team-1", lastText: nil, lastAt: nil, unreadCount: 2)]

        vm.applyParentUnreadDelta(parentId: "team-stranger", delta: 5)

        XCTAssertEqual(vm.conversations.first?.unreadCount, 2)
    }

    func test_topicBumpFlowsThroughPublisherToParentRow() async {
        let defaults = UserDefaults(suiteName: "ConversationsVM-topic-pub-\(UUID().uuidString)")!
        let store = TopicListStore(maxParents: 10, defaults: defaults)
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 0),
        ], forParent: "team-1")

        let vm = ConversationsViewModel(topicStore: store)
        vm.conversations = [makeTeam(id: "team-1", lastText: nil, lastAt: nil, unreadCount: 0)]

        store.bumpUnread(topicId: "t1", parentId: "team-1", by: 2)
        // Let the `.receive(on: DispatchQueue.main)` hop drain.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(vm.conversations.first?.unreadCount, 2)
    }

    // MARK: - Helpers

    private func makeTeam(
        id: String,
        lastText: String?,
        lastAt: String?,
        lastMessage: Message? = nil,
        unreadCount: Int? = 0
    ) -> Conversation {
        Conversation(
            id: id, type: "group", is_group: true,
            group_name: "Team \(id)", group_avatar_url: nil, repo_full_name: nil,
            participants: [], other_user: nil,
            last_message: lastMessage,
            last_message_preview: lastText,
            last_message_text: lastText,
            last_message_at: lastAt,
            unread_count: unreadCount,
            pinned: false, pinned_at: nil, is_request: false, updated_at: nil,
            is_muted: false, has_mention: false, has_reaction: false,
            topics_enabled: true, has_topics: true, topic_chips: nil
        )
    }

    private func makeMessage(
        id: String = UUID().uuidString,
        content: String,
        conversationID: String,
        createdAt: String?,
        topicID: String?
    ) -> Message {
        Message(
            id: id,
            client_message_id: nil,
            conversation_id: conversationID,
            sender: "alice",
            sender_avatar: nil,
            content: content,
            created_at: createdAt,
            edited_at: nil,
            reactions: nil,
            attachment_url: nil,
            type: "user",
            reply_to_id: nil,
            reply: nil,
            attachments: nil,
            unsent_at: nil,
            reactionRows: nil,
            topicId: topicID,
            forwarded_from_original_author: nil
        )
    }
}
