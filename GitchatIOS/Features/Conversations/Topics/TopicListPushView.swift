import SwiftUI

/// iOS pushed view (NavigationStack child) that hosts `TopicListContent`.
/// Pushed from `ConversationsListView` when the user taps a
/// topic-enabled group. Renders a custom 2-line title (group name +
/// member subtitle) in the toolbar and a trailing "+" to create topics.
/// Tapping a topic row pushes `ChatDetailView(.topic(...))` via the
/// embedding NavigationStack's `navigationDestination`.
struct TopicListPushView: View {
    let parent: Conversation
    let onPickTopic: (Topic) -> Void

    @ObservedObject private var presence = PresenceStore.shared
    @State private var showCreate = false

    private var memberSubtitle: String {
        let participants = parent.participantsOrEmpty.map(\.login)
        if participants.isEmpty { return "Members" }
        let onlineCount = participants.filter { presence.isOnline($0) }.count
        if onlineCount > 0 {
            return "\(participants.count) members · \(onlineCount) online"
        }
        return "\(participants.count) members"
    }

    var body: some View {
        TopicListContent(
            parent: parent,
            activeTopicId: nil,
            showCreate: $showCreate,
            onPickTopic: onPickTopic
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(parent.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(memberSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
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
        .task {
            presence.ensure(parent.participantsOrEmpty.map(\.login))
        }
    }
}
