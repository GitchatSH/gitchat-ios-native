import SwiftUI

/// Cross-platform body for the topic list. Wrapped by
/// `TopicListSidebarView` (Mac Catalyst sidebar) and
/// `TopicListPushView` (iOS pushed view). Renders the section'd list
/// of topics with empty/loading/error variants.
struct TopicListContent: View {
    let parent: Conversation
    let activeTopicId: String?
    @Binding var showCreate: Bool
    let onPickTopic: (Topic) -> Void

    @StateObject private var store = TopicListStore.shared
    @State private var isLoading = true
    @State private var loadError: String?

    private var topics: [Topic] { store.topics(forParent: parent.id) }
    private var pinned: [Topic] {
        topics.filter { store.isLocallyPinned(topicId: $0.id, parentId: parent.id) }
    }
    private var unpinned: [Topic] {
        topics.filter { !store.isLocallyPinned(topicId: $0.id, parentId: parent.id) }
    }

    var body: some View {
        content
            .task(id: parent.id) {
                await load()
                // BE emits `topic:message` (and other topic events) to room
                // `conversation:<parentId>`. Without this subscription the
                // receiver never gets realtime topic-row updates on this
                // screen — the preview/timestamp stayed frozen until the
                // user backed out and re-entered. See issue #148.
                SocketClient.shared.subscribe(conversation: parent.id)
            }
            .onDisappear {
                SocketClient.shared.unsubscribe(conversation: parent.id)
            }
            // Note: `TopicListStore.shared` self-subscribes to
            // `.gitchatTopicEvent` so we don't forward here. Forwarding
            // additionally would double-bump unread now that bumping
            // lives inside `applyEvent(.message)`.
    }

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            errorBanner(err)
        } else if isLoading && topics.isEmpty {
            loadingPlaceholder
        } else if topics.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { row(for: $0) }
                }
            }
            Section("All topics") {
                ForEach(unpinned) { row(for: $0) }
            }
        }
        .listStyle(.plain)
        .modifier(TopicListSectionSpacing())
        .listRowSeparator(.hidden)
    }

    private func row(for topic: Topic) -> some View {
        TopicRow(topic: topic,
                 isActive: topic.id == activeTopicId,
                 isPinned: store.isLocallyPinned(topicId: topic.id, parentId: parent.id)) {
            onPickTopic(topic)
        }
        .macHover()
        .contextMenu { contextMenu(for: topic) }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    @ViewBuilder
    private func contextMenu(for topic: Topic) -> some View {
        Button { Task { await markRead(topic) } } label: {
            Label("Mark as read", systemImage: "checkmark.circle")
        }
        // Pin/Unpin is per-device only (matches the VS Code extension's
        // webview-state pin model). No API call, no permission check.
        let pinned = store.isLocallyPinned(topicId: topic.id, parentId: parent.id)
        Button { togglePin(topic) } label: {
            Label(pinned ? "Unpin" : "Pin",
                  systemImage: pinned ? "pin.slash" : "pin")
        }
        if !topic.is_general {
            Button(role: .destructive) { Task { await archive(topic) } } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color("AccentColor"))
            Text("Start a topic")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Topics keep group conversations organized by subject.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button {
                showCreate = true
            } label: {
                Label("New Topic", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 140, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 200, height: 12)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .shimmering()
            }
        }
    }

    private func errorBanner(_ err: String) -> some View {
        VStack(spacing: 12) {
            Text(err).font(.subheadline).foregroundStyle(.red)
            Button("Retry") { Task { await load() } }
        }.padding(24)
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true; loadError = nil
        do {
            let fetched = try await APIClient.shared.fetchTopics(parentId: parent.id)
            store.setTopics(fetched, forParent: parent.id)
        } catch { loadError = "Could not load topics — try again" }
        isLoading = false
    }

    private func markRead(_ t: Topic) async {
        store.clearUnread(topicId: t.id, parentId: parent.id)
        try? await APIClient.shared.markTopicRead(parentId: parent.id, topicId: t.id)
    }

    private func togglePin(_ t: Topic) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            store.togglePin(topicId: t.id, parentId: parent.id)
        }
    }

    private func archive(_ t: Topic) async {
        do {
            _ = try await APIClient.shared.archiveTopic(parentId: parent.id, topicId: t.id)
            store.archive(topicId: t.id, parentId: parent.id)
        } catch let APIError.http(status, body) where status == 403
                                            && (body ?? "").contains("TOPIC_GENERAL_PROTECTED") {
            ToastCenter.shared.show(.error, "Cannot archive General",
                                     "The General topic is protected")
        } catch let APIError.http(status, body) where status == 403 {
            NSLog("[Topic.archive] 403 body=%@", body ?? "<nil>")
            ToastCenter.shared.show(.error, "Could not archive",
                                     "Only the creator or an admin can archive this topic")
        } catch {
            NSLog("[Topic.archive] error=%@", String(describing: error))
            ToastCenter.shared.show(.error, "Could not archive", "Try again")
        }
    }
}

private struct TopicListSectionSpacing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.listSectionSpacing(4)
        } else {
            content
        }
    }
}
