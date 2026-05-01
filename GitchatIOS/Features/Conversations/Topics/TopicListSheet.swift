import SwiftUI

/// iOS / iPad bottom-sheet wrapper around `TopicListContent`.
/// Catalyst uses `TopicListPopover` instead.
struct TopicListSheet: View {
    let parent: Conversation
    let activeTopicId: String?
    let onPickTopic: (Topic) -> Void

    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            TopicListContent(
                parent: parent,
                activeTopicId: activeTopicId,
                showCreate: $showCreate,
                onPickTopic: onPickTopic
            )
            .navigationTitle("Topics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .accessibilityLabel("New Topic")
                }
            }
            .sheet(isPresented: $showCreate) {
                TopicCreateSheet(parent: parent) { newTopic in
                    TopicListStore.shared.append(newTopic, parentId: parent.id)
                }
                .presentationDetents([.medium])
            }
        }
    }
}
