#if targetEnvironment(macCatalyst)
import SwiftUI

/// Catalyst-only wrapper around `TopicListContent`. The header (back ·
/// parent name · members subtitle · menu) is provided by the outer
/// `ConversationsListView` chrome via `.principal` toolbar item when
/// `router.activeForumParent != nil`. This view renders only the topic
/// list body, inset on the trailing side of the sidebar.
struct TopicListSidebarView: View {
    let parent: Conversation

    @StateObject private var router = AppRouter.shared
    @State private var showCreate = false

    var body: some View {
        TopicListContent(
            parent: parent,
            activeTopicId: router.selectedTopic?.topic.id,
            showCreate: $showCreate,
            onPickTopic: { picked in
                router.pickTopic(picked, in: parent)
            }
        )
        .sheet(isPresented: $showCreate) {
            TopicCreateSheet(parent: parent) { newTopic in
                TopicListStore.shared.append(newTopic, parentId: parent.id)
            }
        }
    }
}
#endif
