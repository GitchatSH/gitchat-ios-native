import SwiftUI
import PhotosUI
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var draft = "" {
        didSet { saveDraft() }
    }
    @Published var replyingTo: Message?
    @Published var editingMessage: Message?
    @Published var error: String?
    @Published var uploading = false

    let conversation: Conversation
    private var draftKey: String { "gitchat.draft.\(conversation.id)" }

    init(conversation: Conversation) {
        self.conversation = conversation
        if let saved = UserDefaults.standard.string(forKey: "gitchat.draft.\(conversation.id)") {
            self.draft = saved
        }
    }

    private func saveDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(draft, forKey: draftKey)
        }
    }

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
        UserDefaults.standard.removeObject(forKey: draftKey)
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

    func unsend(_ msg: Message) async {
        do {
            try await APIClient.shared.unsendMessage(messageId: msg.id)
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                messages.remove(at: idx)
            }
            ToastCenter.shared.show(.info, "Unsent")
        } catch {
            ToastCenter.shared.show(.error, "Couldn't unsend", error.localizedDescription)
        }
    }

    func uploadAndSendMany(items: [(Data, String, String)], senderLogin: String?) async {
        guard !items.isEmpty else { return }
        // Compress all
        let compressed = items.map { Self.compressIfImage(data: $0.0, filename: $0.1, mimeType: $0.2) }
        // Optimistic local attachments
        var localURLs: [URL] = []
        var localAttachments: [MessageAttachment] = []
        for (data, filename, _) in compressed {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(filename)")
            try? data.write(to: tmpURL)
            localURLs.append(tmpURL)
            localAttachments.append(MessageAttachment(
                attachment_id: nil, url: tmpURL.absoluteString, type: "image",
                filename: filename, mime_type: "image/jpeg",
                width: nil, height: nil
            ))
        }
        let localID = "local-\(UUID().uuidString)"
        let optimistic = Message(
            id: localID,
            conversation_id: conversation.id,
            sender: senderLogin ?? "me",
            sender_avatar: nil,
            content: "",
            created_at: ISO8601DateFormatter().string(from: Date()),
            edited_at: nil,
            reactions: nil,
            attachment_url: nil,
            type: "user",
            reply_to_id: nil,
            attachments: localAttachments
        )
        messages.append(optimistic)
        Haptics.impact(.light)

        // Upload all in parallel
        do {
            let urls = try await withThrowingTaskGroup(of: (Int, String).self) { group -> [String] in
                for (i, tuple) in compressed.enumerated() {
                    group.addTask {
                        let url = try await APIClient.shared.uploadAttachment(
                            data: tuple.0,
                            filename: tuple.1,
                            mimeType: tuple.2,
                            conversationId: self.conversation.id
                        )
                        return (i, url)
                    }
                }
                var result = Array(repeating: "", count: compressed.count)
                for try await (i, url) in group { result[i] = url }
                return result
            }
            let msg = try await APIClient.shared.sendMessage(
                conversationId: conversation.id,
                body: "",
                attachmentURLs: urls
            )
            if let idx = messages.firstIndex(where: { $0.id == localID }) {
                messages[idx] = msg
            }
            for u in localURLs { try? FileManager.default.removeItem(at: u) }
        } catch {
            messages.removeAll { $0.id == localID }
            ToastCenter.shared.show(.error, "Upload failed", error.localizedDescription)
        }
    }

    func uploadAndSend(data: Data, filename: String, mimeType: String, senderLogin: String?) async {
        // 1. Compress to reasonable size + quality so upload is snappy.
        let (compressed, usedFilename, usedMime) = Self.compressIfImage(
            data: data, filename: filename, mimeType: mimeType
        )

        // 2. Write to a temp file so we can display the local image optimistically.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(usedFilename)")
        try? compressed.write(to: tmpURL)
        let localID = "local-\(UUID().uuidString)"
        let optimistic = Message(
            id: localID,
            conversation_id: conversation.id,
            sender: senderLogin ?? "me",
            sender_avatar: nil,
            content: "",
            created_at: ISO8601DateFormatter().string(from: Date()),
            edited_at: nil,
            reactions: nil,
            attachment_url: tmpURL.absoluteString,
            type: "user",
            reply_to_id: nil
        )
        messages.append(optimistic)
        Haptics.impact(.light)

        // 3. Upload in the background. Keep the optimistic bubble as-is until we
        // have a real server message, then swap.
        do {
            let url = try await APIClient.shared.uploadAttachment(
                data: compressed,
                filename: usedFilename,
                mimeType: usedMime,
                conversationId: conversation.id
            )
            let msg = try await APIClient.shared.sendMessage(
                conversationId: conversation.id,
                body: "",
                attachmentURL: url
            )
            if let idx = messages.firstIndex(where: { $0.id == localID }) {
                messages[idx] = msg
            } else {
                messages.append(msg)
            }
            try? FileManager.default.removeItem(at: tmpURL)
        } catch {
            self.error = error.localizedDescription
            messages.removeAll { $0.id == localID }
            ToastCenter.shared.show(.error, "Upload failed", error.localizedDescription)
        }
    }

    private static func compressIfImage(
        data: Data, filename: String, mimeType: String
    ) -> (Data, String, String) {
        guard mimeType.hasPrefix("image/"), let image = UIImage(data: data) else {
            return (data, filename, mimeType)
        }
        let maxDim: CGFloat = 1600
        let size = image.size
        let scale = min(1, maxDim / max(size.width, size.height))
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        if let jpeg = resized.jpegData(compressionQuality: 0.75) {
            let base = (filename as NSString).deletingPathExtension
            return (jpeg, "\(base).jpg", "image/jpeg")
        }
        return (data, filename, mimeType)
    }
}

struct ChatDetailView: View {
    @StateObject private var vm: ChatViewModel
    @StateObject private var blocks = BlockStore.shared
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var socket: SocketClient
    @State private var photoItem: PhotosPickerItem?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showSearch = false
    @State private var showPinned = false
    @State private var showForward: Message?
    @State private var reactorsFor: Message?
    @State private var reportingMessage: Message?
    @State private var reportReason: String = "Spam"
    @State private var reportDetail: String = ""
    @State private var showReportConfirm = false
    @State private var composerVisible = false
    @State private var showMembers = false
    @FocusState private var composerFocused: Bool

    init(conversation: Conversation) {
        _vm = StateObject(wrappedValue: ChatViewModel(conversation: conversation))
    }

    private var visibleMessages: [Message] {
        vm.messages.filter { !blocks.isBlocked($0.sender) }
    }

    private var mentionSuggestions: [ConversationParticipant] {
        guard vm.conversation.isGroup else { return [] }
        guard let token = currentMentionToken() else { return [] }
        let all = vm.conversation.participantsOrEmpty.filter { $0.login != auth.login }
        if token.isEmpty { return Array(all.prefix(8)) }
        let t = token.lowercased()
        return all.filter {
            $0.login.lowercased().hasPrefix(t) || ($0.name ?? "").lowercased().contains(t)
        }.prefix(8).map { $0 }
    }

    private func currentMentionToken() -> String? {
        let text = vm.draft
        guard let atIdx = text.lastIndex(of: "@") else { return nil }
        // Must be at start or preceded by whitespace
        if atIdx != text.startIndex {
            let prev = text[text.index(before: atIdx)]
            if !prev.isWhitespace { return nil }
        }
        let tail = text[text.index(after: atIdx)...]
        if tail.contains(" ") || tail.contains("\n") { return nil }
        return String(tail)
    }

    private var mentionSuggestionList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(mentionSuggestions) { p in
                    Button {
                        insertMention(p.login)
                    } label: {
                        HStack(spacing: 6) {
                            AvatarView(url: p.avatar_url, size: 22)
                            Text("@\(p.login)")
                                .font(.geist(13, weight: .semibold))
                                .foregroundStyle(Color(.label))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func insertMention(_ login: String) {
        let text = vm.draft
        guard let atIdx = text.lastIndex(of: "@") else { return }
        let before = text[..<atIdx]
        vm.draft = "\(before)@\(login) "
        Haptics.selection()
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
                        ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { idx, msg in
                            let prev = idx > 0 ? visibleMessages[idx - 1] : nil
                            let showHeader = prev?.sender != msg.sender
                            MessageBubble(
                                message: msg,
                                isMe: msg.sender == auth.login,
                                resolvedAvatar: resolveAvatar(for: msg),
                                showHeader: showHeader,
                                onReactionsTap: { reactorsFor = msg },
                                onReplyTap: {
                                    if let targetId = msg.reply?.id {
                                        withAnimation {
                                            proxy.scrollTo(targetId, anchor: .center)
                                        }
                                    }
                                }
                            )
                            .id(msg.id)
                            .padding(.top, showHeader ? 6 : 0)
                            .contextMenu {
                                messageActions(for: msg)
                            } preview: {
                                MessageContextPreview(
                                    message: msg,
                                    isMe: msg.sender == auth.login,
                                    resolvedAvatar: resolveAvatar(for: msg),
                                    onReact: { e in
                                        Task { await vm.react(messageId: msg.id, emoji: e) }
                                    }
                                )
                            }
                            .onTapGesture(count: 2) {
                                Haptics.impact(.light)
                                Task { await vm.react(messageId: msg.id, emoji: "❤️") }
                            }
                        }
                        Color.clear.frame(height: 8).id("__bottom__")
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
                .onChange(of: vm.isLoading) { loading in
                    if !loading, let last = vm.messages.last {
                        DispatchQueue.main.async {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            if composerVisible {
                if vm.replyingTo != nil || vm.editingMessage != nil {
                    replyEditBar
                }
                if !mentionSuggestions.isEmpty {
                    mentionSuggestionList
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
                Menu {
                    if vm.conversation.isGroup {
                        Button {
                            showMembers = true
                        } label: {
                            Label("\(vm.conversation.participantsOrEmpty.count) Members", systemImage: "person.2")
                        }
                    } else if let other = vm.conversation.other_user {
                        NavigationLink(value: ProfileLoginRoute(login: other.login)) {
                            Label("View profile", systemImage: "person.crop.circle")
                        }
                    }
                    Button { showSearch = true } label: { Label("Search", systemImage: "magnifyingglass") }
                    Button { showPinned = true } label: { Label("Pinned messages", systemImage: "pin") }
                    Button {
                        Task {
                            do {
                                if vm.conversation.is_muted == true {
                                    try await APIClient.shared.unmuteConversation(id: vm.conversation.id)
                                    ToastCenter.shared.show(.info, "Unmuted")
                                } else {
                                    try await APIClient.shared.muteConversation(id: vm.conversation.id)
                                    ToastCenter.shared.show(.success, "Muted")
                                }
                            } catch {
                                ToastCenter.shared.show(.error, "Mute failed", error.localizedDescription)
                            }
                        }
                    } label: {
                        Label(vm.conversation.is_muted == true ? "Unmute" : "Mute", systemImage: vm.conversation.is_muted == true ? "bell" : "bell.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .environment(\.colorScheme, .dark)
                .tint(.white)
            }
        }
        .navigationDestination(for: ProfileLoginRoute.self) { route in
            ProfileView(login: route.login)
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack { MessageSearchSheet(conversation: vm.conversation) }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showPinned) {
            NavigationStack { PinnedMessagesSheet(conversation: vm.conversation) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $showForward) { msg in
            NavigationStack { ForwardSheet(message: msg) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $reactorsFor) { msg in
            NavigationStack { ReactorsSheet(message: msg, participants: vm.conversation.participantsOrEmpty + [vm.conversation.other_user].compactMap { $0 }) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
        .onChange(of: photoItems) { newItems in
            guard !newItems.isEmpty else { return }
            Task {
                var loaded: [(Data, String, String)] = []
                for (i, item) in newItems.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        loaded.append((data, "image-\(i).jpg", "image/jpeg"))
                    }
                }
                await vm.uploadAndSendMany(items: loaded, senderLogin: auth.login)
                photoItems = []
            }
        }
    }

    @ViewBuilder
    private func messageActions(for msg: Message) -> some View {
        Button {
            vm.replyingTo = msg
            vm.editingMessage = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { composerFocused = true }
        } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        Button {
            UIPasteboard.general.string = msg.content
            ToastCenter.shared.show(.success, "Copied")
        } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button {
            Task { await vm.togglePin(msg) }
        } label: { Label("Pin", systemImage: "pin") }
        Button {
            showForward = msg
        } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        if msg.sender == auth.login {
            Button { vm.startEdit(msg) } label: { Label("Edit", systemImage: "pencil") }
            Button {
                Task { await vm.unsend(msg) }
            } label: { Label("Unsend", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) {
                Task { await vm.delete(msg) }
            } label: { Label("Delete", systemImage: "trash") }
        } else {
            Button(role: .destructive) {
                reportingMessage = msg
            } label: { Label("Report", systemImage: "flag") }
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
            PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                Image(systemName: "paperclip")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .modifier(GlassPill())
            }
            .disabled(vm.uploading)

            TextField(vm.editingMessage != nil ? "Edit message" : "Message", text: $vm.draft, axis: .vertical)
                .focused($composerFocused)
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

struct MessageContextPreview: View {
    let message: Message
    let isMe: Bool
    let resolvedAvatar: String?
    let onReact: (String) -> Void

    private let emojis = ["❤️", "👍", "👎", "😂", "😮", "🎉"]

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(emojis, id: \.self) { e in
                    Button {
                        Haptics.selection()
                        onReact(e)
                    } label: {
                        Text(e)
                            .font(.system(size: 26))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            MessageBubble(
                message: message,
                isMe: isMe,
                resolvedAvatar: resolvedAvatar,
                showHeader: true
            )
        }
        .padding(12)
    }
}

struct ReactorsSheet: View {
    let message: Message
    let participants: [ConversationParticipant]
    @Environment(\.dismiss) private var dismiss

    private var grouped: [(String, [String])] {
        let rows = message.reactionRows ?? []
        var bag: [String: [String]] = [:]
        for r in rows {
            bag[r.emoji, default: []].append(r.user_login ?? "")
        }
        return bag.map { ($0.key, $0.value) }.sorted { $0.1.count > $1.1.count }
    }

    private func avatar(for login: String) -> String? {
        participants.first(where: { $0.login == login })?.avatar_url
    }

    var body: some View {
        List {
            ForEach(grouped, id: \.0) { emoji, logins in
                Section {
                    ForEach(logins, id: \.self) { login in
                        HStack(spacing: 12) {
                            AvatarView(url: avatar(for: login), size: 36)
                            Text("@\(login)").font(.subheadline)
                            Spacer()
                            Text(emoji).font(.system(size: 22))
                        }
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("\(emoji)  \(logins.count)")
                        .font(.headline)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if grouped.isEmpty {
                ContentUnavailableCompat(
                    title: "No reactions",
                    systemImage: "face.smiling",
                    description: "Tap an emoji to react."
                )
            }
        }
        .navigationTitle("Reactions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
    }
}

struct MessageSearchSheet: View {
    let conversation: Conversation
    @State private var query: String = ""
    @State private var results: [Message] = []
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(results) { m in
            VStack(alignment: .leading, spacing: 4) {
                Text("@\(m.sender)").font(.caption.bold()).foregroundStyle(.secondary)
                Text(m.content).font(.subheadline)
                Text(RelativeTime.format(m.created_at))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .overlay {
            if isLoading {
                ProgressView()
            } else if results.isEmpty && !query.isEmpty {
                ContentUnavailableCompat(
                    title: "No matches",
                    systemImage: "magnifyingglass",
                    description: "Try another search."
                )
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search this chat")
        .onChange(of: query) { newValue in
            Task { await runSearch(newValue) }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
    }

    private func runSearch(_ q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { results = []; return }
        isLoading = true; defer { isLoading = false }
        do {
            results = try await APIClient.shared.searchMessagesInConversation(id: conversation.id, q: trimmed)
        } catch { results = [] }
    }
}

struct PinnedMessagesSheet: View {
    let conversation: Conversation
    @State private var messages: [Message] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if isLoading {
                SkeletonList(count: 5, avatarSize: 28)
            } else if messages.isEmpty {
                ContentUnavailableCompat(
                    title: "No pinned messages",
                    systemImage: "pin",
                    description: "Long-press a message and tap Pin."
                )
            } else {
                List(messages) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("@\(m.sender)").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(m.content).font(.subheadline)
                        Text(RelativeTime.format(m.created_at))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Pinned")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        .task {
            do {
                messages = try await APIClient.shared.pinnedMessages(conversationId: conversation.id)
            } catch {}
            isLoading = false
        }
    }
}

struct ForwardSheet: View {
    let message: Message
    @State private var conversations: [Conversation] = []
    @State private var selected: Set<String> = []
    @State private var isSending = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(conversations) { c in
            Button {
                Haptics.selection()
                if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
            } label: {
                HStack {
                    AvatarView(url: c.displayAvatarURL, size: 36)
                    Text(c.displayTitle).foregroundStyle(Color(.label))
                    Spacer()
                    Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(c.id) ? Color.accentColor : Color(.tertiaryLabel))
                }
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationTitle("Forward to…")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    Task {
                        isSending = true
                        do {
                            try await APIClient.shared.forwardMessage(messageId: message.id, toConversationIds: Array(selected))
                            ToastCenter.shared.show(.success, "Forwarded", "to \(selected.count) chat\(selected.count == 1 ? "" : "s")")
                            dismiss()
                        } catch {
                            ToastCenter.shared.show(.error, "Forward failed", error.localizedDescription)
                        }
                        isSending = false
                    }
                }
                .disabled(selected.isEmpty || isSending)
            }
        }
        .task {
            do {
                let resp = try await APIClient.shared.listConversations()
                conversations = resp.conversations
            } catch {}
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

struct MessageBubble: View {
    let message: Message
    let isMe: Bool
    var resolvedAvatar: String? = nil
    var showHeader: Bool = true
    var onReactionsTap: (() -> Void)? = nil
    var onReplyTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMe { Spacer(minLength: 40) } else {
                if showHeader {
                    AvatarView(url: resolvedAvatar ?? message.sender_avatar, size: 28)
                } else {
                    Color.clear.frame(width: 28, height: 28)
                }
            }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if !isMe && showHeader {
                    Text(message.sender).font(.caption2).foregroundStyle(.secondary)
                }
                if let reply = message.reply {
                    replyPreview(reply)
                        .contentShape(Rectangle())
                        .onTapGesture { onReplyTap?() }
                }
                bubbleContent
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
                    .contentShape(Rectangle())
                    .onTapGesture { onReactionsTap?() }
                }
            }
            if !isMe { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private func attachmentImage(for url: URL) -> some View {
        if url.isFileURL, let ui = UIImage(contentsOfFile: url.path) {
            Image(uiImage: ui).resizable().scaledToFit()
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: Color(.secondarySystemBackground).frame(height: 160)
                }
            }
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
        if message.unsent_at != nil {
            Text("Message unsent")
                .italic()
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if let atts = message.attachments, !atts.isEmpty {
                    attachmentGrid(atts)
                } else if let url = message.attachment_url, let imageURL = URL(string: url) {
                    attachmentImage(for: imageURL)
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

    @ViewBuilder
    private func attachmentGrid(_ atts: [MessageAttachment]) -> some View {
        let cols = atts.count == 1 ? 1 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: cols), spacing: 4) {
            ForEach(atts) { a in
                if let url = URL(string: a.url) {
                    attachmentImage(for: url)
                        .frame(maxWidth: atts.count == 1 ? 240 : 120, maxHeight: atts.count == 1 ? 240 : 120)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(maxWidth: atts.count == 1 ? 240 : 248)
    }
}

