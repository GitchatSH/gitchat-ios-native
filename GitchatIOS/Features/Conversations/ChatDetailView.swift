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
            ToastCenter.shared.show(.success, "Pinned message")
        } catch {
            // If already pinned, unpin instead.
            do {
                try await APIClient.shared.unpinMessage(conversationId: conversation.id, messageId: msg.id)
                ToastCenter.shared.show(.info, "Unpinned message")
            } catch {
                self.error = error.localizedDescription
                ToastCenter.shared.show(.error, "Couldn't pin", error.localizedDescription)
            }
        }
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
    @State private var showMembers = false

    init(conversation: Conversation) {
        _vm = StateObject(wrappedValue: ChatViewModel(conversation: conversation))
    }

    private var visibleMessages: [Message] {
        vm.messages.filter { !blocks.isBlocked($0.sender) }
    }

    private func resolveAvatar(for msg: Message) -> String? {
        if let url = msg.sender_avatar { return url }
        if let match = vm.conversation.participantsOrEmpty.first(where: { $0.login == msg.sender }) {
            return match.avatar_url
        }
        if let other = vm.conversation.other_user, other.login == msg.sender {
            return other.avatar_url
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleMessages) { msg in
                            MessageBubble(
                                message: msg,
                                isMe: msg.sender == auth.login,
                                resolvedAvatar: resolveAvatar(for: msg)
                            ) {
                                messageActions(for: msg)
                            }
                            .id(msg.id)
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                )
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if vm.conversation.isGroup {
                    Button {
                        showMembers = true
                    } label: {
                        Text("\(vm.conversation.participantsOrEmpty.count)")
                            .font(.geist(14, weight: .bold))
                    }
                } else if let other = vm.conversation.other_user {
                    NavigationLink(value: ProfileLoginRoute(login: other.login)) {
                        AsyncImage(url: other.avatar_url.flatMap(URL.init(string:))) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            default:
                                Color.accentColor.opacity(0.2)
                                    .overlay(Image(systemName: "person.fill").foregroundStyle(.white))
                            }
                        }
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationDestination(for: ProfileLoginRoute.self) { route in
            ProfileView(login: route.login)
        }
        .sheet(isPresented: $showMembers) {
            NavigationStack {
                MembersSheet(participants: vm.conversation.participantsOrEmpty)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
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
        HStack(spacing: 8) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "paperclip")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .modifier(GlassPill())
            }
            .disabled(vm.uploading)

            TextField(vm.editingMessage != nil ? "Edit message" : "Message", text: $vm.draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(Color.clear)
                .modifier(GlassPill())

            Button {
                Task { await vm.send() }
            } label: {
                Group {
                    if vm.uploading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(vm.draft.isEmpty ? Color.gray.opacity(0.5) : Color.accentColor)
                )
            }
            .disabled(vm.draft.isEmpty || vm.uploading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct ProfileLoginRoute: Hashable {
    let login: String
}

struct MembersSheet: View {
    let participants: [ConversationParticipant]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if participants.isEmpty {
                ContentUnavailableCompat(
                    title: "No members",
                    systemImage: "person.2",
                    description: "This group has no visible members."
                )
            } else {
                List(participants) { p in
                    NavigationLink(value: ProfileLoginRoute(login: p.login)) {
                        HStack(spacing: 12) {
                            AvatarView(url: p.avatar_url, size: 40)
                            VStack(alignment: .leading) {
                                Text(p.name ?? p.login).font(.headline)
                                Text("@\(p.login)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("\(participants.count) Member\(participants.count == 1 ? "" : "s")")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ProfileLoginRoute.self) { route in
            ProfileView(login: route.login)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}

private struct GlassPill: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

struct MessageBubble<Actions: View>: View {
    let message: Message
    let isMe: Bool
    var resolvedAvatar: String? = nil
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMe { Spacer(minLength: 40) } else {
                AvatarView(url: resolvedAvatar ?? message.sender_avatar, size: 28)
            }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if !isMe {
                    Text(message.sender).font(.caption2).foregroundStyle(.secondary)
                }
                if let reply = message.reply {
                    replyPreview(reply)
                }
                bubbleContent
                    .contextMenu { actions() }
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

    private func replyPreview(_ reply: ReplyPreview) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isMe ? Color.accentColor : Color.secondary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if let login = reply.sender_login {
                    Text("@\(login)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isMe ? Color.accentColor : Color.secondary)
                }
                Text(reply.body ?? "…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
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
        }
    }
}
