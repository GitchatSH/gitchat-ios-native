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
    @State private var showInviteLink = false
    @State private var showGroupSettings = false
    @State private var showDeleteGroupConfirm = false
    @State private var deletingGroup = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool
    @State private var pendingDropImages: [UIImage] = []
    @State private var showDropConfirm = false
    @State private var dropCaption = ""
    @State private var cropTarget: Int?
    @State private var isDragOver = false
    @StateObject private var clipboard = ClipboardWatcher()
    @State private var menuTarget: MessageMenuTarget?

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
            .animation(keyboard.lastChange.swiftUIAnimation, value: keyboard.height)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .environment(\.chatTheme, .default)
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
                    ReplyEditBar(
                        editing: vm.editingMessage,
                        replyingTo: vm.replyingTo,
                        onDismiss: {
                            if vm.editingMessage != nil { vm.cancelEdit() }
                            else { vm.replyingTo = nil }
                        }
                    )
                }
                if !mentionSuggestions.isEmpty {
                    mentionSuggestionList
                }
                if let img = clipboard.pendingImage {
                    clipboardChip(for: img)
                }
                composer
                    .overlay(alignment: .topTrailing) {
                        if !isAtBottom {
                            JumpToBottomButton(action: { scrollToBottomToken &+= 1 })
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
        .modifier(MessageMenuHostModifier(
            target: $menuTarget,
            auth: auth,
            vm: vm,
            resolvedAvatar: menuTarget.flatMap { resolveAvatar(for: $0.message) },
            onQuickReact: { msg, emoji in quickReact(msg, emoji) },
            onMoreReactions: { msg in reactingFor = msg },
            actions: { msg in AnyView(menuActionRows(for: msg)) }
        ))
        .modifier(CatalystDropModifier(isDragOver: $isDragOver, dragOverlay: dragOverlay, onDrop: handleDrop))
        .sheet(isPresented: $showDropConfirm) { dropPreviewSheet }
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
            // Handle invite links (both gitchat:// and https://*.gitchat.sh)
            // in-app so a tap on a shared invite routes to the preview
            // sheet instead of opening Safari and 404'ing on BE's /invite
            // route (Universal Links / AASA aren't set up yet).
            if AppRouter.shared.handleDeepLink(url) {
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
        .modifier(GroupManagementSheets(
            conversation: vm.conversation,
            showInviteLink: $showInviteLink,
            showGroupSettings: $showGroupSettings,
            showDeleteConfirm: $showDeleteGroupConfirm,
            onSettingsSaved: { newName, newAvatarUrl in
                vm.applyLocalMetadata(name: newName, avatarUrl: newAvatarUrl)
                Task { await vm.load() }
            },
            onDeleteConfirmed: { Task { await disbandGroup() } }
        ))
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
        .modifier(ChatLifecycleModifier(
            vm: vm,
            scrollToBottomToken: $scrollToBottomToken,
            composerFocused: composerFocused,
            myLogin: auth.login,
            onConversationUpdated: syncMutedFromCache
        ))
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
                // Route picked photos through the same preview sheet
                // used by drag-and-drop and paste — gives users a
                // chance to review, caption, or crop before sending.
                // Also merges into any existing pendingDropImages so
                // the "Add more" tile in the preview sheet appends
                // rather than replaces.
                var collected: [UIImage] = []
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        collected.append(img)
                    }
                }
                photoItems = []
                guard !collected.isEmpty else { return }
                if showDropConfirm {
                    pendingDropImages.append(contentsOf: collected)
                } else {
                    pendingDropImages = collected
                    showDropConfirm = true
                }
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
                bubbleContextMenu: nil
            )
            .padding(.top, showHeader ? 6 : 0)
            // Long-press opens the menu overlay. We pass a placeholder
            // source frame (centered); overlay positioning uses the
            // stack layout — feeding a live per-cell frame would
            // require a GeometryReader whose .onChange fires on every
            // scroll tick and rebuilds the whole chat body (tested:
            // measurable jank on a 500-message list).
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.28)
                    .onEnded { _ in
                        Haptics.impact(.medium)
                        menuTarget = MessageMenuTarget(
                            message: msg,
                            isMe: msg.sender == auth.login,
                            sourceFrame: .zero
                        )
                    }
            )
            .swipeToReply(isMe: msg.sender == auth.login) {
                vm.replyingTo = msg
                vm.editingMessage = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { composerFocused = true }
            }
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

    @ViewBuilder
    private var dragOverlay: some View {
        if isDragOver {
            ZStack {
                Color.black.opacity(0.001)
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .foregroundStyle(Color("AccentColor"))
                    .background(Color("AccentColor").opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 16)))
                    .padding(12)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 32))
                                .foregroundStyle(Color("AccentColor"))
                            Text("Drop images here")
                                .font(.headline)
                                .foregroundStyle(Color("AccentColor"))
                        }
                    }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var dropPreviewSheet: some View {
        ImageSendPreview(
            images: $pendingDropImages,
            caption: $dropCaption,
            cropTarget: $cropTarget,
            photoItems: $photoItems,
            onCancel: {
                cropTarget = nil
                pendingDropImages = []
                dropCaption = ""
                showDropConfirm = false
            },
            onSend: {
                cropTarget = nil
                showDropConfirm = false
                sendDroppedImages()
            }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let lock = NSLock()
        var collected: [UIImage] = []
        let group = DispatchGroup()

        func append(_ image: UIImage) {
            lock.lock(); collected.append(image); lock.unlock()
        }

        for provider in providers {
            // Try the cheapest path first — NSItemProvider natively
            // vending a UIImage (PhotosPicker, Photos.app drag, Catalyst
            // Finder drags of common formats).
            if provider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { obj, _ in
                    if let img = obj as? UIImage { append(img) }
                    group.leave()
                }
                continue
            }

            let types = provider.registeredTypeIdentifiers
            // Raw image data under a known image UTI.
            let imageTypes = ["public.jpeg", "public.png", "public.heic", "public.image"]
            if let uti = types.first(where: { imageTypes.contains($0) }) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: uti) { data, _ in
                    if let data, let img = UIImage(data: data) { append(img) }
                    group.leave()
                }
                continue
            }

            // File URL (Finder drag, Catalyst local file).
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                group.enter()
                provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                    var url: URL?
                    if let u = item as? URL { url = u }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    if let url, let img = UIImage(contentsOfFile: url.path) {
                        append(img)
                    }
                    group.leave()
                }
                continue
            }

            // Generic URL (Safari image drag usually lands here). Fetch
            // synchronously in the background — small cost for a one-off
            // drop, and keeps the UX consistent with drag-drop elsewhere.
            if provider.hasItemConformingToTypeIdentifier("public.url") {
                group.enter()
                provider.loadItem(forTypeIdentifier: "public.url") { item, _ in
                    defer { group.leave() }
                    let url: URL? = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        ?? (item as? NSString).flatMap { URL(string: $0 as String) }
                    guard let url,
                          let data = try? Data(contentsOf: url),
                          let img = UIImage(data: data) else { return }
                    append(img)
                }
                continue
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
        // Resize to match the PhotosPicker path (compressIfImage runs
        // 1600 max dim @ quality 0.75). Drop / paste used to skip this
        // step and send photos at full device resolution.
        let items: [(Data, String, String)] = images.enumerated().compactMap { i, img in
            let resized = ChatViewModel.resizeForUpload(img)
            guard let d = resized.jpegData(compressionQuality: 0.85) else { return nil }
            return (d, "image-\(i).jpg", "image/jpeg")
        }
        guard !items.isEmpty else { return }
        Task { await vm.uploadAndSendMany(items: items, senderLogin: auth.login) }
    }

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
                    Button {
                        showInviteLink = true
                    } label: {
                        Label("Invite link", systemImage: "link")
                    }
                    Button {
                        showGroupSettings = true
                    } label: {
                        Label("Edit group", systemImage: "pencil")
                    }
                } else if let other = vm.conversation.other_user {
                    NavigationLink(value: ProfileLoginRoute(login: other.login)) {
                        Label("View profile", systemImage: "person.crop.circle")
                    }
                    Button {
                        Task { await convertToGroupAndAddMember() }
                    } label: {
                        Label("Add to conversation", systemImage: "person.crop.circle.badge.plus")
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
                    Button(role: .destructive) {
                        showDeleteGroupConfirm = true
                    } label: {
                        Label("Delete group", systemImage: "trash")
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

    /// Action list rendered inside `MessageMenuOverlay` — same behaviours
    /// as `messageActions(for:)` but styled as overlay rows instead of
    /// iOS ControlGroup items. Each tap also dismisses the overlay.
    @ViewBuilder
    private func menuActionRows(for msg: Message) -> some View {
        let dismiss: () -> Void = { menuTarget = nil }
        MessageMenuActionButton(title: "Reply", systemImage: "arrowshape.turn.up.left") {
            dismiss()
            vm.replyingTo = msg
            vm.editingMessage = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { composerFocused = true }
        }
        if !msg.content.isEmpty {
            MessageMenuActionButton(title: "Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = msg.content
                ToastCenter.shared.show(.success, "Copied")
                dismiss()
            }
        }
        if let imageURLs = Self.imageAttachmentURLs(msg), !imageURLs.isEmpty {
            MessageMenuActionButton(title: "Copy Image", systemImage: "photo.on.rectangle") {
                copyImageToClipboard(urls: imageURLs)
                dismiss()
            }
        }
        MessageMenuActionButton(
            title: vm.pinnedIds.contains(msg.id) ? "Unpin" : "Pin",
            systemImage: vm.pinnedIds.contains(msg.id) ? "pin.slash" : "pin"
        ) {
            Task { await vm.togglePin(msg) }
            dismiss()
        }
        MessageMenuActionButton(title: "Forward", systemImage: "arrowshape.turn.up.right") {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { showForward = msg }
        }
        if vm.conversation.isGroup {
            let seenBy = vm.seenByLogins(for: msg)
            MessageMenuActionButton(
                title: seenBy.isEmpty ? "Seen by" : "Seen by \(seenBy.count)",
                systemImage: "eye"
            ) {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { seenByFor = msg }
            }
        }
        if msg.sender == auth.login {
            MessageMenuActionButton(title: "Edit", systemImage: "pencil") {
                vm.startEdit(msg)
                dismiss()
            }
            MessageMenuActionButton(title: "Unsend", systemImage: "arrow.uturn.backward") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { confirmUnsend = msg }
            }
            MessageMenuActionButton(title: "Delete", systemImage: "trash", role: .destructive) {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { confirmDelete = msg }
            }
        } else {
            MessageMenuActionButton(title: "Report", systemImage: "flag", role: .destructive) {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { reportingMessage = msg }
            }
        }
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
                    .background(Color("AccentColor"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    /// Compact chip above the composer that surfaces an image sitting on
    /// the pasteboard. Tap → route through the same crop/caption/send
    /// flow drag-drop uses. X → dedup this image so it doesn't re-prompt.
    private func clipboardChip(for image: UIImage) -> some View {
        HStack(spacing: 10) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text("Image in clipboard")
                    .font(.system(size: 13, weight: .semibold))
                Text("Tap to attach").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Paste") {
                Haptics.impact(.light)
                pendingDropImages = [image]
                showDropConfirm = true
                clipboard.consume()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                clipboard.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss clipboard image")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                    Circle().fill(vm.draft.isEmpty ? Color.gray.opacity(0.5) : Color("AccentColor"))
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

    /// Promote the current DM to a group then show the add-member sheet
    /// so the user can pick a third participant. BE returns the updated
    /// Conversation; we re-hydrate via vm.load() so the header + ••• menu
    /// switch into group mode.
    private func convertToGroupAndAddMember() async {
        do {
            _ = try await APIClient.shared.convertToGroup(id: vm.conversation.id)
            await vm.load()
            showAddMember = true
        } catch {
            ToastCenter.shared.show(.error, "Couldn't convert", error.localizedDescription)
        }
    }

    private func disbandGroup() async {
        deletingGroup = true
        defer { deletingGroup = false }
        do {
            try await APIClient.shared.disbandGroup(id: vm.conversation.id)
            ToastCenter.shared.show(.success, "Group deleted")
            dismiss()
        } catch {
            ToastCenter.shared.show(.error, "Couldn't delete", error.localizedDescription)
        }
    }

    /// Pull the freshest Conversation for the open chat from the shared
    /// conversations cache. Called when a `conversation:updated` socket
    /// event fires so the header (title / avatar / bell-slash) reflects
    /// remote edits without requiring the user to back out and re-enter.
    private func syncMutedFromCache() {
        guard let fresh = ConversationsCache.shared.get()?.first(where: { $0.id == vm.conversation.id }) else { return }
        vm.conversation = fresh
        vm.isMuted = fresh.is_muted == true
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
