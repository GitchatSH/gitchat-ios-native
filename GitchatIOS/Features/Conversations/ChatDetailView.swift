import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct ChatDetailView: View {
    @StateObject private var vm: ChatViewModel
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var socket: SocketClient
    @State private var photoItem: PhotosPickerItem?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showSearch = false
    @State private var showPinned = false
    @State private var showForward: Message?
    @State private var reactorsFor: Message?
    @State private var seenByFor: Message?
    @State private var reactingFor: Message?
    @State private var imagePreview: ImagePreviewState?
    @State private var pulsingId: String?
    @State private var webURL: URL?
    @State private var profileRoute: ProfileLoginRoute?
    @State private var confirmDelete: Message?
    @State private var confirmUnsend: Message?
    @State private var pendingJumpId: String?
    @StateObject private var keyboard = KeyboardObserver()
    @State private var reportingMessage: Message?
    @State private var reportReason: String = "Spam"
    @State private var reportDetail: String = ""
    @State private var showReportConfirm = false
    @State private var composerVisible = true
    @State private var isAtBottom: Bool = true
    @State private var scrollToBottomToken: Int = 0
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var blocks = BlockStore.shared
    @State private var showMembers = false
    @State private var showAddMember = false
    @State private var showLeaveConfirm = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool
    #if targetEnvironment(macCatalyst)
    @State private var isDragOver = false
    @State private var pendingDropImages: [UIImage] = []
    @State private var showDropConfirm = false
    @State private var dropCaption = ""
    #endif

    init(conversation: Conversation) {
        _vm = StateObject(wrappedValue: ChatViewModel(conversation: conversation))
    }

    // MARK: - Derived state

    private var visibleMessages: [Message] {
        vm.messages.filter { !blocks.isBlocked($0.sender) }
    }

    /// For 1:1 chats, returns the other user's login if they are
    /// currently blocked. Group chats return nil — blocking inside a
    /// group only filters messages, it doesn't disable the chat.
    private var otherBlockedLogin: String? {
        guard !vm.conversation.isGroup,
              let login = vm.conversation.other_user?.login,
              blocks.isBlocked(login)
        else { return nil }
        return login
    }

    private var mentionSuggestions: [ConversationParticipant] {
        guard vm.conversation.isGroup else { return [] }
        guard let token = currentMentionToken() else { return [] }
        let all = vm.conversation.participantsOrEmpty.filter { $0.login != auth.login }
        if token.isEmpty { return all }
        let t = token.lowercased()
        return all.filter {
            $0.login.lowercased().hasPrefix(t) || ($0.name ?? "").lowercased().contains(t)
        }
    }

    private func currentMentionToken() -> String? {
        let text = vm.draft
        guard let atIdx = text.lastIndex(of: "@") else { return nil }
        if atIdx != text.startIndex {
            let prev = text[text.index(before: atIdx)]
            if !prev.isWhitespace { return nil }
        }
        let tail = text[text.index(after: atIdx)...]
        if tail.contains(" ") || tail.contains("\n") { return nil }
        return String(tail)
    }

    private func insertMention(_ login: String) {
        let text = vm.draft
        guard let atIdx = text.lastIndex(of: "@") else { return }
        let before = text[..<atIdx]
        vm.draft = "\(before)@\(login) "
        Haptics.selection()
    }

    private var shouldShowSeen: Bool {
        guard let otherReadAt = vm.otherReadAt else { return false }
        guard let lastMine = visibleMessages.last(where: { $0.sender == auth.login }) else { return false }
        return (lastMine.created_at ?? "") <= otherReadAt
    }

    private var safeAreaBottom: CGFloat {
        UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows.first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
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

    // MARK: - Body

    var body: some View {
        chatBody
            .padding(.bottom, keyboard.height > 0 ? keyboard.height - safeAreaBottom : 0)
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    @ViewBuilder
    private var messagesList: some View {
        if vm.isLoading && visibleMessages.isEmpty {
            ChatSkeleton()
        } else {
            chatCollection
        }
    }

    private var chatCollection: some View {
        ChatCollectionView(
            items: visibleMessages,
            typingUsers: Array(vm.typingUsers),
            showSeen: shouldShowSeen && !vm.conversation.isGroup,
            seenAvatarURL: vm.conversation.other_user?.avatar_url ?? vm.conversation.other_user.map { "https://github.com/\($0.login).png" },
            pinnedIds: vm.pinnedIds,
            readCursors: vm.readCursors,
            pulsingId: pulsingId,
            scrollToId: pendingJumpId,
            isLoadingMore: vm.isLoadingMore,
            bottomInset: keyboard.height,
            scrollToBottomToken: scrollToBottomToken,
            isAtBottom: $isAtBottom,
            onScrollToIdConsumed: { pendingJumpId = nil },
            onTopReached: { Task { await vm.loadMoreIfNeeded() } },
            cellBuilder: { msg, idx in messageRow(for: msg, at: idx) }
        )
        .onTapGesture { composerFocused = false }
    }

    private var chatBody: some View {
        ZStack {
            ChatBackground()
                .ignoresSafeArea()
            VStack(spacing: 0) {
            messagesList
            if let blockedLogin = otherBlockedLogin {
                blockedBanner(login: blockedLogin)
            } else if composerVisible {
                if vm.replyingTo != nil || vm.editingMessage != nil {
                    replyEditBar
                }
                if !mentionSuggestions.isEmpty {
                    mentionSuggestionList
                }
                composer
                    .overlay(alignment: .topTrailing) {
                        if !isAtBottom {
                            jumpToBottomButton
                                .padding(.trailing, 6)
                                .offset(y: -52)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isAtBottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            }
        }
        #if targetEnvironment(macCatalyst)
        .overlay { dragOverlay }
        .animation(.easeInOut(duration: 0.15), value: isDragOver)
        .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
            return true
        }
        .sheet(isPresented: $showDropConfirm) { dropPreviewSheet }
        #endif
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            chatToolbar
            ToolbarItem(placement: .principal) {
                ChatDetailTitleBar(
                    conversation: vm.conversation,
                    vm: vm,
                    onTap: {
                        if vm.conversation.isGroup { showMembers = true }
                    }
                )
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
            NavigationStack {
                PinnedMessagesSheet(conversation: vm.conversation) { id in
                    pendingJumpId = id
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $showForward) { msg in
            NavigationStack { ForwardSheet(message: msg) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $imagePreview) { state in
            ImageViewerSheet(urls: state.urls, startIndex: state.index)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
        .alert("Delete message?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { msg in
            Button("Delete", role: .destructive) {
                Task { await vm.delete(msg) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the message for you only.")
        }
        .modifier(LeaveGroupAlert(show: $showLeaveConfirm, conversation: vm.conversation, onLeave: { dismiss() }))
        .alert("Unsend message?", isPresented: Binding(
            get: { confirmUnsend != nil },
            set: { if !$0 { confirmUnsend = nil } }
        ), presenting: confirmUnsend) { msg in
            Button("Unsend", role: .destructive) {
                Task { await vm.unsend(msg) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Everyone in the chat will see the message was unsent.")
        }
        .sheet(item: $profileRoute) { route in
            NavigationStack { ProfileView(login: route.login) }
        }
        .sheet(item: Binding<URLItem?>(
            get: { webURL.map(URLItem.init) },
            set: { webURL = $0?.url }
        )) { item in
            SafariSheet(url: item.url).ignoresSafeArea()
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "gitchat", url.host == "user" {
                let login = url.pathComponents.dropFirst().first ?? ""
                if !login.isEmpty {
                    profileRoute = ProfileLoginRoute(login: login)
                }
                return .handled
            }
            #if targetEnvironment(macCatalyst)
            UIApplication.shared.open(url)
            #else
            webURL = url
            #endif
            return .handled
        })
        .sheet(item: $reactingFor) { msg in
            EmojiPickerSheet { emoji in
                vm.applyOptimisticReaction(messageId: msg.id, emoji: emoji, myLogin: auth.login)
                Task { try? await APIClient.shared.react(messageId: msg.id, emoji: emoji, add: true) }
                reactingFor = nil
            }
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $seenByFor) { msg in
            NavigationStack {
                SeenBySheet(
                    message: msg,
                    readCursors: vm.readCursors,
                    participants: vm.conversation.participantsOrEmpty,
                    myLogin: auth.login
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $reactorsFor) { msg in
            NavigationStack {
                ReactorsSheet(
                    message: msg,
                    participants: vm.conversation.participantsOrEmpty + [vm.conversation.other_user].compactMap { $0 },
                    myLogin: auth.login
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showMembers) {
            NavigationStack {
                MembersSheet(
                    conversationId: vm.conversation.id,
                    participants: vm.conversation.participantsOrEmpty
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddMember) {
            AddMemberSheet(
                conversationId: vm.conversation.id,
                existingLogins: Set(vm.conversation.participantsOrEmpty.map(\.login))
            ) {
                Task { await vm.load() }
            }
        }
        .sheet(item: $reportingMessage) { msg in reportSheet(for: msg) }
        .alert("Thanks — we'll review it within 24 hours.", isPresented: $showReportConfirm) {
            Button("OK", role: .cancel) {}
        }
        .task { await onAppearTask() }
        .onAppear {
            // If we were opened from a notification that carried a
            // target message id, hand it to the jump-and-pulse path.
            if let mid = router.pendingMessageId {
                pendingJumpId = mid
                router.pendingMessageId = nil
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await vm.load() } }
        }
        .onChange(of: vm.messages.last?.id) { _ in
            // Whenever the latest message is one I just sent, force the
            // collection view to scroll to it — even if the user had
            // scrolled up before tapping send.
            guard let last = vm.messages.last, last.sender == auth.login else { return }
            scrollToBottomToken &+= 1
        }
        .onChange(of: composerFocused) { focused in
            // When the user focuses the composer to start typing, jump
            // to the latest message so the keyboard doesn't cover the
            // conversation they're replying to.
            if focused { scrollToBottomToken &+= 1 }
        }
        .onDisappear { onDisappearCleanup() }
        .onChange(of: vm.draft) { newValue in
            socket.emitTyping(
                conversationId: vm.conversation.id,
                isTyping: !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
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

    // MARK: - Row builder

    @ViewBuilder
    private func messageRow(for msg: Message, at idx: Int) -> some View {
        if let t = msg.type, t != "user" {
            SystemMessageRow(message: msg) {
                if let target = msg.reply_to_id {
                    pendingJumpId = target
                } else if let target = vm.pinnedIds.first {
                    pendingJumpId = target
                } else {
                    showPinned = true
                }
            }
        } else {
            let prev = idx > 0 ? visibleMessages[idx - 1] : nil
            let showHeader = prev?.sender != msg.sender || (prev?.type ?? "user") != "user"
            MessageBubble(
                message: msg,
                isMe: msg.sender == auth.login,
                myLogin: auth.login,
                resolvedAvatar: resolveAvatar(for: msg),
                showHeader: showHeader,
                isPinned: vm.pinnedIds.contains(msg.id),
                onReactionsTap: { reactorsFor = msg },
                onReplyTap: { jumpToReply(from: msg) },
                onAttachmentTap: { url in
                    let urls = (msg.attachments?.map(\.url) ?? [msg.attachment_url].compactMap { $0 })
                    if let start = urls.firstIndex(of: url) {
                        imagePreview = ImagePreviewState(urls: urls, index: start)
                    }
                },
                onPinTap: { showPinned = true },
                onAvatarTap: { profileRoute = ProfileLoginRoute(login: msg.sender) },
                isPulsing: pulsingId == msg.id,
                bubbleContextMenu: { AnyView(messageActions(for: msg)) }
            )
            .padding(.top, showHeader ? 6 : 0)
            .onTapGesture(count: 2) {
                Haptics.impact(.light)
                vm.applyOptimisticReaction(messageId: msg.id, emoji: "❤️", myLogin: auth.login)
                Task { try? await APIClient.shared.react(messageId: msg.id, emoji: "❤️", add: true) }
            }

            if vm.conversation.isGroup {
                let cursors = vm.seenCursorLogins(for: msg, at: idx)
                if !cursors.isEmpty {
                    let isMe = msg.sender == auth.login
                    HStack(spacing: 0) {
                        if isMe { Spacer() }
                        seenByAvatars(cursors)
                            .padding(isMe ? .trailing : .leading, isMe ? 6 : 36)
                            .onTapGesture { seenByFor = msg }
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                        if !isMe { Spacer() }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: cursors)
                }
            }
        }
    }

    @ViewBuilder
    private func seenByAvatars(_ logins: [String]) -> some View {
        let shown = Array(logins.prefix(10))
        let extra = logins.count - shown.count
        HStack(spacing: -4) {
            ForEach(shown, id: \.self) { login in
                let p = vm.conversation.participantsOrEmpty.first { $0.login == login }
                SeenAvatarWithTooltip(avatarURL: p?.avatar_url, name: p?.name ?? login)
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    @ViewBuilder
    private var dragOverlay: some View {
        if isDragOver {
            ZStack {
                Color.black.opacity(0.001)
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 16)))
                    .padding(12)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 32))
                                .foregroundStyle(Color.accentColor)
                            Text("Drop images here")
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var dropPreviewSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(Array(pendingDropImages.enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 150)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding()
                }
                HStack(spacing: 8) {
                    TextField("Add a message…", text: $dropCaption)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        showDropConfirm = false
                        sendDroppedImages()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("Send \(pendingDropImages.count) image\(pendingDropImages.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pendingDropImages = []
                        dropCaption = ""
                        showDropConfirm = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func macPasteImages() {
        let pb = UIPasteboard.general
        var images: [UIImage] = []
        if let imgs = pb.images, !imgs.isEmpty {
            images = imgs
        } else if let img = pb.image {
            images = [img]
        }
        guard !images.isEmpty else {
            ToastCenter.shared.show(.info, "No images on clipboard")
            return
        }
        pendingDropImages = images
        showDropConfirm = true
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let lock = NSLock()
        var collected: [UIImage] = []
        let group = DispatchGroup()
        for provider in providers {
            if provider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { obj, _ in
                    if let img = obj as? UIImage { lock.lock(); collected.append(img); lock.unlock() }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                group.enter()
                provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                    var url: URL?
                    if let u = item as? URL { url = u }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    if let url, let img = UIImage(contentsOfFile: url.path) {
                        lock.lock(); collected.append(img); lock.unlock()
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            guard !collected.isEmpty else { return }
            pendingDropImages = collected
            showDropConfirm = true
        }
    }

    private func sendDroppedImages() {
        let images = pendingDropImages
        let caption = dropCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingDropImages = []
        dropCaption = ""
        if !caption.isEmpty {
            vm.draft = caption
            Task { await vm.send() }
        }
        let items: [(Data, String, String)] = images.enumerated().compactMap { i, img in
            guard let d = img.jpegData(compressionQuality: 0.9) else { return nil }
            return (d, "image-\(i).jpg", "image/jpeg")
        }
        guard !items.isEmpty else { return }
        Task { await vm.uploadAndSendMany(items: items, senderLogin: auth.login) }
    }
    #endif

    private static func imageAttachmentURLs(_ msg: Message) -> [String]? {
        if let atts = msg.attachments, !atts.isEmpty {
            let imgs = atts
                .filter { ($0.type == "image") || ($0.mime_type?.hasPrefix("image/") == true) }
                .map(\.url)
            return imgs.isEmpty ? nil : imgs
        }
        if let url = msg.attachment_url, !url.isEmpty {
            return [url]
        }
        return nil
    }

    private func copyImageToClipboard(urls: [String]) {
        guard let first = urls.first, let url = URL(string: first) else { return }
        Task {
            if let img = await ImageCache.shared.load(url) {
                UIPasteboard.general.image = img
                ToastCenter.shared.show(.success, "Image copied")
            } else {
                ToastCenter.shared.show(.error, "Couldn't copy image")
            }
        }
    }

    private func quickReact(_ msg: Message, _ emoji: String) {
        Haptics.impact(.light)
        vm.applyOptimisticReaction(messageId: msg.id, emoji: emoji, myLogin: auth.login)
        AnalyticsTracker.trackReaction(emoji: emoji)
        Task { try? await APIClient.shared.react(messageId: msg.id, emoji: emoji, add: true) }
    }


    private func jumpToReply(from msg: Message) {
        guard let targetId = msg.reply?.id else { return }
        pendingJumpId = targetId
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeInOut(duration: 0.25)) { pulsingId = targetId }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeInOut(duration: 0.3)) { pulsingId = nil }
            }
        }
    }

    // MARK: - Toolbar / composer / reply bar / mention chips

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                if vm.conversation.isGroup {
                    Button {
                        showMembers = true
                    } label: {
                        Label("\(vm.conversation.participantsOrEmpty.count) Members", systemImage: "person.2")
                    }
                    Button {
                        showAddMember = true
                    } label: {
                        Label("Add member", systemImage: "person.crop.circle.badge.plus")
                    }
                } else if let other = vm.conversation.other_user {
                    NavigationLink(value: ProfileLoginRoute(login: other.login)) {
                        Label("View profile", systemImage: "person.crop.circle")
                    }
                }
                Button { showSearch = true } label: { Label("Search", systemImage: "magnifyingglass") }
                Button { showPinned = true } label: { Label("Pinned messages", systemImage: "pin") }
                Button {
                    Task { await vm.toggleMute() }
                } label: {
                    Label(
                        vm.isMuted ? "Unmute" : "Mute",
                        systemImage: vm.isMuted ? "bell" : "bell.slash"
                    )
                }
                if vm.conversation.isGroup {
                    Divider()
                    Button(role: .destructive) {
                        showLeaveConfirm = true
                    } label: {
                        Label("Leave group", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .tint(.primary)
        }
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

    @ViewBuilder
    private func messageActions(for msg: Message) -> some View {
        // iOS context menu inline ControlGroup caps at 4 items per row.
        // Two stacked rows: row 1 = 4 emoji, row 2 = 3 emoji + chevron
        // that opens the full reaction picker.
        #if targetEnvironment(macCatalyst)
        if #available(iOS 16.4, *) {
            ControlGroup {
                Button { quickReact(msg, "❤️") } label: { Text("❤️") }
                Button { quickReact(msg, "👍") } label: { Text("👍") }
                Button { quickReact(msg, "😂") } label: { Text("😂") }
                Button { quickReact(msg, "🔥") } label: { Text("🔥") }
            }
            .controlGroupStyle(.compactMenu)
            ControlGroup {
                Button { quickReact(msg, "🎉") } label: { Text("🎉") }
                Button { quickReact(msg, "👀") } label: { Text("👀") }
                Button { quickReact(msg, "🙏") } label: { Text("🙏") }
                Button { quickReact(msg, "😢") } label: { Text("😢") }
            }
            .controlGroupStyle(.compactMenu)
        }
        Button {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                reactingFor = msg
            }
        } label: {
            Label("More reactions…", systemImage: "face.smiling")
        }
        #else
        if #available(iOS 16.4, *) {
            ControlGroup {
                Button { quickReact(msg, "❤️") } label: { Text("❤️") }
                Button { quickReact(msg, "👍") } label: { Text("👍") }
                Button { quickReact(msg, "😂") } label: { Text("😂") }
                Button { quickReact(msg, "🔥") } label: { Text("🔥") }
            }
            .controlGroupStyle(.compactMenu)
            ControlGroup {
                Button { quickReact(msg, "🎉") } label: { Text("🎉") }
                Button { quickReact(msg, "👀") } label: { Text("👀") }
                Button { quickReact(msg, "🙏") } label: { Text("🙏") }
                Button {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        reactingFor = msg
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
            }
            .controlGroupStyle(.compactMenu)
        } else {
            Button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    reactingFor = msg
                }
            } label: {
                Label("React", systemImage: "face.smiling")
            }
        }
        #endif
        Button {
            vm.replyingTo = msg
            vm.editingMessage = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { composerFocused = true }
        } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        if !msg.content.isEmpty {
            Button {
                UIPasteboard.general.string = msg.content
                ToastCenter.shared.show(.success, "Copied")
            } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        if let imageURLs = Self.imageAttachmentURLs(msg), !imageURLs.isEmpty {
            Button {
                copyImageToClipboard(urls: imageURLs)
            } label: { Label("Copy Image", systemImage: "photo.on.rectangle") }
        }
        Button {
            Task { await vm.togglePin(msg) }
        } label: {
            Label(
                vm.pinnedIds.contains(msg.id) ? "Unpin" : "Pin",
                systemImage: vm.pinnedIds.contains(msg.id) ? "pin.slash" : "pin"
            )
        }
        Button {
            showForward = msg
        } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        if vm.conversation.isGroup {
            let seenBy = vm.seenByLogins(for: msg)
            Button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    seenByFor = msg
                }
            } label: {
                Label(
                    seenBy.isEmpty ? "Seen by" : "Seen by \(seenBy.count)",
                    systemImage: "eye"
                )
            }
        }
        if msg.sender == auth.login {
            Button { vm.startEdit(msg) } label: { Label("Edit", systemImage: "pencil") }
            Button {
                confirmUnsend = msg
            } label: { Label("Unsend", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) {
                confirmDelete = msg
            } label: { Label("Delete", systemImage: "trash") }
            .tint(.red)
        } else {
            Button(role: .destructive) {
                reportingMessage = msg
            } label: { Label("Report", systemImage: "flag") }
            .tint(.red)
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

    @ViewBuilder
    private var jumpToBottomButton: some View {
        let action: () -> Void = {
            Haptics.selection()
            scrollToBottomToken &+= 1
        }
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
            }
            .buttonBorderShape(.circle)
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(Color(.label))
        } else {
            Button(action: action) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(.label))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .instantTooltip("Jump to latest")
        }
    }

    private func blockedBanner(login: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.secondary)
                Text("You blocked @\(login). Unblock to keep chatting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            Button {
                blocks.unblock(login)
                ToastCenter.shared.show(.success, "Unblocked", "@\(login)")
            } label: {
                Text("Unblock")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private var composerTextField: some View {
        let placeholder = vm.editingMessage != nil ? "Edit message" : "Message"
        #if targetEnvironment(macCatalyst)
        // Mac: single-line TextField so Return triggers .onSubmit
        // (multi-line text fields swallow Return for newline). Long
        // messages still wrap visually because the field has a max
        // width but no fixed height.
        TextField(placeholder, text: $vm.draft)
            .focused($composerFocused)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(Color.clear)
            .modifier(GlassPill())
            .onSubmit {
                Task {
                    await vm.send()
                    DispatchQueue.main.async { composerFocused = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { composerFocused = true }
                }
            }
            .submitLabel(.send)
        #else
        TextField(placeholder, text: $vm.draft, axis: .vertical)
            .focused($composerFocused)
            .lineLimit(1...5)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(Color.clear)
            .modifier(GlassPill())
        #endif
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                Image(systemName: "paperclip")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .modifier(GlassPill())
            }
            .disabled(vm.uploading)

            #if targetEnvironment(macCatalyst)
            Button { macPasteImages() } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .modifier(GlassPill())
            }
            .disabled(vm.uploading)
            #endif

            composerTextField

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

    // MARK: - Report sheet

    @ViewBuilder
    private func reportSheet(for msg: Message) -> some View {
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

    // MARK: - Lifecycle

    private func onAppearTask() async {
        socket.currentConversationId = vm.conversation.id
        ActiveConversationTracker.shared.id = vm.conversation.id
        await vm.load()
        socket.subscribe(conversation: vm.conversation.id)
        socket.onMessageSent = { msg in
            guard msg.conversation_id == vm.conversation.id else { return }
            if vm.messages.contains(where: { $0.id == msg.id }) { return }
            // If we're showing an optimistic copy of the same message
            // (same sender + body, local- prefixed id), swap it rather
            // than appending — otherwise we'd end up with both a local
            // and a server version in the list.
            MessageBubble.seenIds.insert(msg.id)
            if let idx = vm.messages.firstIndex(where: {
                $0.id.hasPrefix("local-") && $0.sender == msg.sender && $0.content == msg.content
            }) {
                vm.messages[idx] = msg
            } else {
                vm.messages.append(msg)
                // Mark read immediately when a new message arrives
                // while the chat is open, so the conversation list
                // doesn't show an unread badge when we back out.
                if msg.sender != auth.login {
                    Task { try? await APIClient.shared.markRead(conversationId: vm.conversation.id) }
                }
            }
        }
        socket.onTyping = { convId, login, typing in
            guard convId == vm.conversation.id, login != auth.login else { return }
            if typing { vm.typingUsers.insert(login) }
            else { vm.typingUsers.remove(login) }
        }
        socket.onConversationRead = { convId, login, readAt in
            guard convId == vm.conversation.id, login != auth.login else { return }
            let ts = readAt ?? ISO8601DateFormatter().string(from: Date())
            vm.otherReadAt = ts
            vm.readCursors[login] = ts
        }
        socket.onMessagePinned = { convId, msgId in
            guard convId == vm.conversation.id else { return }
            vm.pinnedIds.insert(msgId)
        }
        socket.onMessageUnpinned = { convId, msgId in
            guard convId == vm.conversation.id else { return }
            vm.pinnedIds.remove(msgId)
        }
    }

    private func onDisappearCleanup() {
        socket.unsubscribe(conversation: vm.conversation.id)
        socket.emitTyping(conversationId: vm.conversation.id, isTyping: false)
        if socket.currentConversationId == vm.conversation.id {
            socket.currentConversationId = nil
            ActiveConversationTracker.shared.id = nil
        }
    }
}

private struct LeaveGroupAlert: ViewModifier {
    @Binding var show: Bool
    let conversation: Conversation
    let onLeave: () -> Void

    func body(content: Content) -> some View {
        content.alert("Leave group?", isPresented: $show) {
            Button("Leave", role: .destructive) {
                Task {
                    do {
                        try await APIClient.shared.leaveGroup(conversationId: conversation.id)
                        ToastCenter.shared.show(.success, "Left group", conversation.displayTitle)
                        onLeave()
                    } catch {
                        ToastCenter.shared.show(.error, "Couldn't leave", error.localizedDescription)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stop receiving messages from this group.")
        }
    }
}
