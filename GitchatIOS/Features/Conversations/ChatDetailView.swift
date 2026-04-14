import SwiftUI
import PhotosUI
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var draft = ""
    @Published var replyingTo: Message?
    @Published var editingMessage: Message?
    @Published var error: String?
    @Published var uploading = false

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
        let replyId = replyingTo?.id
        replyingTo = nil
        do {
            if let editing = editingMessage {
                try await APIClient.shared.editMessage(
                    conversationId: conversation.id,
                    messageId: editing.id,
                    body: body
                )
                if let idx = messages.firstIndex(where: { $0.id == editing.id }) {
                    messages[idx] = Message(
                        id: editing.id,
                        conversation_id: editing.conversation_id,
                        sender: editing.sender,
                        sender_avatar: editing.sender_avatar,
                        content: body,
                        created_at: editing.created_at,
                        edited_at: ISO8601DateFormatter().string(from: Date()),
                        reactions: editing.reactions,
                        attachment_url: editing.attachment_url,
                        type: editing.type,
                        reply_to_id: editing.reply_to_id
                    )
                }
                editingMessage = nil
            } else {
                let msg = try await APIClient.shared.sendMessage(
                    conversationId: conversation.id,
                    body: body,
                    replyTo: replyId
                )
                messages.append(msg)
                Haptics.impact(.light)
            }
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
            ToastCenter.shared.show(.error, "Send failed", error.localizedDescription)
        }
    }

    func react(messageId: String, emoji: String) async {
        try? await APIClient.shared.react(messageId: messageId, emoji: emoji, add: true)
    }

    func delete(_ msg: Message) async {
        do {
            try await APIClient.shared.deleteMessage(conversationId: conversation.id, messageId: msg.id)
            messages.removeAll { $0.id == msg.id }
        } catch { self.error = error.localizedDescription }
    }

    func togglePin(_ msg: Message) async {
        do {
            try await APIClient.shared.pinMessage(conversationId: conversation.id, messageId: msg.id)
        } catch { self.error = error.localizedDescription }
    }

    func startEdit(_ msg: Message) {
        editingMessage = msg
        draft = msg.content
        replyingTo = nil
    }

    func cancelEdit() {
        editingMessage = nil
        draft = ""
    }

    func uploadAndSend(data: Data, filename: String, mimeType: String) async {
        uploading = true
        defer { uploading = false }
        do {
            let url = try await APIClient.shared.uploadAttachment(
                data: data,
                filename: filename,
                mimeType: mimeType,
                conversationId: conversation.id
            )
            let msg = try await APIClient.shared.sendMessage(
                conversationId: conversation.id,
                body: "",
                attachmentURL: url
            )
            messages.append(msg)
        } catch { self.error = error.localizedDescription }
    }
}

struct ChatDetailView: View {
    @StateObject private var vm: ChatViewModel
    @StateObject private var blocks = BlockStore.shared
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var socket: SocketClient
    @State private var photoItem: PhotosPickerItem?
    @State private var reportingMessage: Message?
    @State private var reportReason: String = "Spam"
    @State private var reportDetail: String = ""
    @State private var showReportConfirm = false
    @State private var composerVisible = false

    init(conversation: Conversation) {
        _vm = StateObject(wrappedValue: ChatViewModel(conversation: conversation))
    }

    private var visibleMessages: [Message] {
        vm.messages.filter { !blocks.isBlocked($0.sender) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleMessages) { msg in
                            MessageBubble(message: msg, isMe: msg.sender == auth.login)
                                .id(msg.id)
                                .contextMenu {
                                    messageActions(for: msg)
                                }
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
            if composerVisible {
                if vm.replyingTo != nil || vm.editingMessage != nil {
                    replyEditBar
                }
                composer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle(vm.conversation.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.05)) {
                composerVisible = true
            }
        }
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
        .sheet(item: $reportingMessage) { msg in
            NavigationStack {
                Form {
                    Section("What's wrong?") {
                        Picker("Reason", selection: $reportReason) {
                            Text("Spam").tag("Spam")
                            Text("Harassment").tag("Harassment")
                            Text("Hate speech").tag("Hate")
                            Text("Sexual content").tag("Sexual")
                            Text("Violence or self-harm").tag("Violence")
                            Text("Other").tag("Other")
                        }
                    }
                    Section("Details (optional)") {
                        TextEditor(text: $reportDetail)
                            .frame(minHeight: 80)
                    }
                    Section {
                        Button {
                            Task {
                                try? await APIClient.shared.reportMessage(
                                    messageId: msg.id,
                                    reason: reportReason,
                                    detail: reportDetail.isEmpty ? nil : reportDetail
                                )
                                blocks.block(msg.sender)
                                reportReason = "Spam"
                                reportDetail = ""
                                reportingMessage = nil
                                showReportConfirm = true
                            }
                        } label: {
                            HStack { Spacer(); Text("Report and block").bold(); Spacer() }
                        }
                        .foregroundStyle(.red)
                    }
                }
                .navigationTitle("Report message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { reportingMessage = nil }
                    }
                }
            }
        }
        .alert("Thanks — we'll review it within 24 hours.", isPresented: $showReportConfirm) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: photoItem) { newItem in
            Task {
                guard let item = newItem,
                      let data = try? await item.loadTransferable(type: Data.self) else { return }
                await vm.uploadAndSend(data: data, filename: "image.jpg", mimeType: "image/jpeg")
                photoItem = nil
            }
        }
    }

    @ViewBuilder
    private func messageActions(for msg: Message) -> some View {
        Button {
            vm.replyingTo = msg
            vm.editingMessage = nil
        } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        Button {
            UIPasteboard.general.string = msg.content
        } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button {
            Task { await vm.togglePin(msg) }
        } label: { Label("Pin", systemImage: "pin") }
        Button { Task { await vm.react(messageId: msg.id, emoji: "👍") } } label: {
            Label("React 👍", systemImage: "hand.thumbsup")
        }
        Button { Task { await vm.react(messageId: msg.id, emoji: "❤️") } } label: {
            Label("React ❤️", systemImage: "heart")
        }
        if msg.sender == auth.login {
            Button { vm.startEdit(msg) } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) {
                Task { await vm.delete(msg) }
            } label: { Label("Delete", systemImage: "trash") }
        } else {
            Button(role: .destructive) {
                reportingMessage = msg
            } label: { Label("Report", systemImage: "flag") }
            Button(role: .destructive) {
                blocks.block(msg.sender)
            } label: { Label("Block @\(msg.sender)", systemImage: "hand.raised") }
        }
    }

    private var replyEditBar: some View {
        HStack {
            Image(systemName: vm.editingMessage != nil ? "pencil" : "arrowshape.turn.up.left")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.editingMessage != nil ? "Editing" : "Replying to \(vm.replyingTo?.sender ?? "")")
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
                Text((vm.editingMessage ?? vm.replyingTo)?.content ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                if vm.editingMessage != nil { vm.cancelEdit() }
                else { vm.replyingTo = nil }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var composer: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            }
            .disabled(vm.uploading)

            TextField(vm.editingMessage != nil ? "Edit message" : "Message", text: $vm.draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: Capsule())

            Button {
                Task { await vm.send() }
            } label: {
                if vm.uploading {
                    ProgressView().tint(Color.accentColor)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(vm.draft.isEmpty ? .gray : .accentColor)
                }
            }
            .disabled(vm.draft.isEmpty || vm.uploading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(GlassBarBackground())
    }
}

private struct GlassBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        } else {
            content.background(.ultraThinMaterial)
        }
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
                if let url = message.attachment_url, let imageURL = URL(string: url) {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFit()
                        default: Color(.secondarySystemBackground).frame(height: 160)
                        }
                    }
                    .frame(maxWidth: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(
                            isMe ? Color.accentColor : Color(.secondarySystemBackground)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(isMe ? .white : .primary)
                }
                if message.edited_at != nil {
                    Text("edited").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if let reactions = message.reactions, !reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(reactions, id: \.emoji) { r in
                            Text("\(r.emoji) \(r.count)")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            if !isMe { Spacer(minLength: 40) }
        }
    }
}
