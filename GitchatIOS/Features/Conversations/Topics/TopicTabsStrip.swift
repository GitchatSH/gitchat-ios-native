#if targetEnvironment(macCatalyst)
import SwiftUI

/// Telegram-Desktop-style horizontal topic tabs strip rendered above
/// the chat body on Mac Catalyst. Each chip switches the chat target
/// to that topic; the trailing `+` button opens `TopicCreateSheet`.
///
/// Hosted via `.safeAreaInset(edge: .top)` on `ChatView` in
/// `ChatDetailView.chatShell`, gated `#if targetEnvironment(macCatalyst)`.
struct TopicTabsStrip: View {
    let parent: Conversation
    let activeTopicId: String?
    let onPickTopic: (Topic) -> Void

    @StateObject private var store = TopicListStore.shared
    @State private var showCreate = false

    private var topics: [Topic] {
        let all = store.topics(forParent: parent.id)
        return all.sorted { a, b in
            if a.is_general != b.is_general { return a.is_general }
            let aPin = store.isLocallyPinned(topicId: a.id, parentId: parent.id)
            let bPin = store.isLocallyPinned(topicId: b.id, parentId: parent.id)
            if aPin != bPin { return aPin }
            return (a.last_message_at ?? "") > (b.last_message_at ?? "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(topics) { topic in
                        chip(for: topic)
                    }
                    createButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Divider()
        }
        .background(Color(.secondarySystemBackground))
        .task { await loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .gitchatTopicEvent)) { note in
            if let evt = note.object as? TopicSocketEvent { store.applyEvent(evt) }
        }
        .sheet(isPresented: $showCreate) {
            TopicCreateSheet(parent: parent) { newTopic in
                store.append(newTopic, parentId: parent.id)
            }
        }
    }

    @ViewBuilder
    private func chip(for topic: Topic) -> some View {
        let isActive = topic.id == activeTopicId
        Button {
            onPickTopic(topic)
        } label: {
            HStack(spacing: 6) {
                Text(topic.displayEmoji).font(.body)
                Text(topic.name)
                    .font(.system(.body, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color("AccentColor") : .primary)
                    .lineLimit(1)
                if topic.unread_count > 0 {
                    Text(topic.unread_count > 99 ? "99+" : "\(topic.unread_count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color("AccentColor"), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color("AccentColor").opacity(0.15) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .macHover()
        .contextMenu { contextMenu(for: topic) }
        .accessibilityLabel("\(topic.name)\(isActive ? ", selected" : "")")
    }

    private var createButton: some View {
        Button { showCreate = true } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .macHover()
        .accessibilityLabel("New Topic")
    }

    @ViewBuilder
    private func contextMenu(for topic: Topic) -> some View {
        Button { Task { await markRead(topic) } } label: {
            Label("Mark as read", systemImage: "checkmark.circle")
        }
        let pinned = store.isLocallyPinned(topicId: topic.id, parentId: parent.id)
        Button { store.togglePin(topicId: topic.id, parentId: parent.id) } label: {
            Label(pinned ? "Unpin" : "Pin",
                  systemImage: pinned ? "pin.slash" : "pin")
        }
        if !topic.is_general {
            Button(role: .destructive) { Task { await archive(topic) } } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    // MARK: - Actions

    private func loadIfNeeded() async {
        guard store.topics(forParent: parent.id).isEmpty else { return }
        if let fetched = try? await APIClient.shared.fetchTopics(parentId: parent.id) {
            store.setTopics(fetched, forParent: parent.id)
        }
    }

    private func markRead(_ t: Topic) async {
        store.clearUnread(topicId: t.id, parentId: parent.id)
        try? await APIClient.shared.markTopicRead(parentId: parent.id, topicId: t.id)
    }

    private func archive(_ t: Topic) async {
        do {
            _ = try await APIClient.shared.archiveTopic(parentId: parent.id, topicId: t.id)
            store.archive(topicId: t.id, parentId: parent.id)
        } catch let APIError.http(status, body) where status == 403
                                            && (body ?? "").contains("TOPIC_GENERAL_PROTECTED") {
            ToastCenter.shared.show(.error, "Cannot archive General",
                                     "The General topic is protected")
        } catch let APIError.http(status, _) where status == 403 {
            ToastCenter.shared.show(.error, "Could not archive",
                                     "Only the creator or an admin can archive this topic")
        } catch {
            ToastCenter.shared.show(.error, "Could not archive", "Try again")
        }
    }
}
#endif
