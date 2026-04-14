import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var draft = ""
    @Published var error: String?

    let conversation: Conversation

    init(conversation: Conversation) { self.conversation = conversation }

    func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            let resp = try await APIClient.shared.getConversationMessages(id: conversation.id)
            self.messages = resp.messages.reversed()
            try? await APIClient.shared.markRead(conversationId: conversation.id)
        } catch { self.error = error.localizedDescription }
    }

    func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        do {
            let msg = try await APIClient.shared.sendMessage(conversationId: conversation.id, body: body)
            messages.append(msg)
        } catch { self.error = error.localizedDescription }
    }

    func react(messageId: String, emoji: String) async {
        try? await APIClient.shared.react(messageId: messageId, emoji: emoji, add: true)
    }
}

struct ChatDetailView: View {
    @StateObject private var vm: ChatViewModel
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var socket: SocketClient

    init(conversation: Conversation) {
        _vm = StateObject(wrappedValue: ChatViewModel(conversation: conversation))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vm.messages) { msg in
                            MessageBubble(message: msg, isMe: msg.sender == auth.login)
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: vm.messages.count) { _ in
                    if let last = vm.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            composer
        }
        .navigationTitle(vm.conversation.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.load()
            socket.subscribe(conversation: vm.conversation.id)
            socket.onMessageSent = { msg in
                if msg.conversation_id == vm.conversation.id {
                    if !vm.messages.contains(where: { $0.id == msg.id }) {
                        vm.messages.append(msg)
                    }
                }
            }
        }
        .onDisappear {
            socket.unsubscribe(conversation: vm.conversation.id)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $vm.draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
            Button {
                Task { await vm.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(vm.draft.isEmpty ? .gray : .accentColor)
            }
            .disabled(vm.draft.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct MessageBubble: View {
    let message: Message
    let isMe: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMe { Spacer(minLength: 40) } else {
                AvatarView(url: message.sender_avatar, size: 28)
            }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if !isMe {
                    Text(message.sender).font(.caption2).foregroundStyle(.secondary)
                }
                Text(message.content)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(
                        isMe ? Color.accentColor : Color(.secondarySystemBackground),
                        in: .rect(cornerRadius: 18)
                    )
                    .foregroundStyle(isMe ? .white : .primary)
                if let reactions = message.reactions, !reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(reactions, id: \.emoji) { r in
                            Text("\(r.emoji) \(r.count)")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.ultraThinMaterial, in: .capsule)
                        }
                    }
                }
            }
            if !isMe { Spacer(minLength: 40) }
        }
    }
}
