import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Host view for a single conversation. Owns navigation, sheets,
/// alerts, drag-drop, and view-model wiring. The scrollable area +
/// composer + menu overlay live inside `ChatView` () — this
/// view is the shell that surrounds them.
///
/// Migration notes (vs. the pre-rewrite ChatDetailView):
/// - Dropped `keyboard = KeyboardObserver()` — ChatView owns its own
///   `KeyboardState` which drives the composer's bottom inset
///   directly. Removes the manual `.padding(.bottom, ...)` dance.
/// - Dropped `composerFocused` @FocusState — the composer exposes a
///   `FocusProxy` which `ChatView` uses internally after Reply / Edit
///   dispatch.
/// - Dropped inline `messageRow` / `seenByAvatars` / `messageActions`
///   / composer / reply bar / mention / clipboard chip / jump-to-bottom
///   / blocked banner. These moved into V2 components.
struct ChatDetailView: View {
    @StateObject private var vm: ChatViewModel
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var socket: SocketClient

    @State private var photoItems: [PhotosPickerItem] = []

    // Sheet + alert presentation state.
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
    @State private var reportingMessage: Message?
    @State private var reportReason: String = "Spam"
    @State private var reportDetail: String = ""
    @State private var showReportConfirm = false
    @State private var composerVisible = true
    @State private var isAtBottom: Bool = true
    @State private var scrollToBottomToken: Int = 0
    @State private var showMembers = false
    @State private var showAddMember = false
    @State private var showLeaveConfirm = false
    @State private var showInviteLink = false
    @State private var showGroupSettings = false
    @State private var showDeleteGroupConfirm = false
    @State private var deletingGroup = false

    // Drag-drop / clipboard-paste plumbing.
    @State private var pendingDropImages: [UIImage] = []
    @State private var showDropConfirm = false
    @State private var dropCaption = ""
    @State private var cropTarget: Int?
    @State private var isDragOver = false
    @StateObject private var clipboard = ClipboardWatcher()

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var blocks = BlockStore.shared
    @ObservedObject private var outbox = OutboxStore.shared
    /// Namespace for the iOS 18+ zoom transition between an
    /// attachment tile and the full-screen image viewer pushed via
    /// `navigationDestination(item:)`.
    @Namespace private var imageZoomNamespace

    init(conversation: Conversation) {
        _vm = StateObject(wrappedValue: ChatViewModel(conversation: conversation))
    }

    // MARK: - Derived state

    private var visibleMessages: [Message] {
        vm.visibleMessages.filter { !blocks.isBlocked($0.sender) }
    }

    /// For 1:1 chats, returns the other user's login if they are
    /// currently blocked. Group chats return nil — blocking inside a
    /// group only filters messages.
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

    private var pendingClipboardBinding: Binding<UIImage?> {
        Binding(
            get: { clipboard.pendingImage },
            set: { _ in /* driven by ClipboardWatcher; writes via consume/dismiss */ }
        )
    }

    // MARK: - Body

    var body: some View {
        chatShell
            .task { await onAppearTask() }
            .onAppear {
                if let mid = router.pendingMessageId {
                    pendingJumpId = mid
                    router.pendingMessageId = nil
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await vm.load() } }
            }
            .onChange(of: vm.messages.last?.id) { _ in
                guard let last = vm.messages.last else { return }
                // Tail-follow rules:
                // - Always scroll on own sends (the user just hit
                //   Send and wants to see their bubble).
                // - Scroll on incoming only when the user is still
                //   parked near the bottom (mirrors iMessage /
                //   Telegram). Otherwise leave the offset alone so
                //   browsing old messages isn't yanked.
                if last.sender == auth.login || isAtBottom {
                    scrollToBottomToken &+= 1
                }
            }
            .onChange(of: vm.draft) { newValue in
                socket.emitTyping(
                    conversationId: vm.conversation.id,
                    isTyping: !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .onChange(of: photoItems) { newItems in
                guard !newItems.isEmpty else { return }
                Task { await routePickedPhotos(newItems) }
            }
            .onDisappear { onDisappearCleanup() }
            .onReceive(NotificationCenter.default.publisher(for: .gitchatConversationUpdated)) { _ in
                syncMutedFromCache()
            }
    }

    @ViewBuilder
    private var chatShell: some View {
        ChatView(
            vm: vm,
            myLogin: auth.login,
            visibleMessages: visibleMessages,
            showSeen: shouldShowSeen && !vm.conversation.isGroup,
            seenAvatarURL: vm.conversation.other_user?.avatar_url
                ?? vm.conversation.other_user.map { "https://github.com/\($0.login).png" },
            pulsingId: $pulsingId,
            pendingJumpId: $pendingJumpId,
            isAtBottom: $isAtBottom,
            scrollToBottomToken: $scrollToBottomToken,
            photoItems: $photoItems,
            pendingClipboardImage: pendingClipboardBinding,
            composerVisible: $composerVisible,
            imageZoomNamespace: imageZoomNamespace,
            mentionSuggestions: mentionSuggestions,
            resolveAvatar: { resolveAvatar(for: $0) },
            seenByLogins: { vm.seenByLogins(for: $0) },
            seenCursorLogins: { msg, nextCreatedAt in
                vm.conversation.isGroup ? vm.seenCursorLogins(for: msg, nextCreatedAt: nextCreatedAt) : []
            },
            participants: vm.conversation.participantsOrEmpty,
            blockedBannerLogin: otherBlockedLogin,
            onUnblock: { login in
                blocks.unblock(login)
                ToastCenter.shared.show(.success, "Unblocked", "@\(login)")
            },
            actions: chatViewActions
        )
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
        // Image viewer pushed as a navigation destination so iOS 18+
        // can run the zoom transition between the tapped attachment
        // tile (matchedTransitionSource inside ChatAttachmentsGrid)
        // and the full-screen viewer. On iOS 16 (our minimum), the
        // navigationDestination(item:) overload isn't available, so
        // older builds fall back to the legacy full-screen cover in
        // the sheets modifier.
        .modifier(ImageViewerDestinationModifier(
            imagePreview: $imagePreview,
            namespace: imageZoomNamespace
        ))
        .modifier(ChatDetailSheets(
            showSearch: $showSearch,
            showPinned: $showPinned,
            showForward: $showForward,
            imagePreview: $imagePreview,
            profileRoute: $profileRoute,
            webURL: $webURL,
            reactingFor: $reactingFor,
            seenByFor: $seenByFor,
            reactorsFor: $reactorsFor,
            showMembers: $showMembers,
            showAddMember: $showAddMember,
            reportingMessage: $reportingMessage,
            showReportConfirm: $showReportConfirm,
            confirmDelete: $confirmDelete,
            confirmUnsend: $confirmUnsend,
            showLeaveConfirm: $showLeaveConfirm,
            showInviteLink: $showInviteLink,
            showGroupSettings: $showGroupSettings,
            showDeleteGroupConfirm: $showDeleteGroupConfirm,
            pendingJumpId: $pendingJumpId,
            reportReason: $reportReason,
            reportDetail: $reportDetail,
            vm: vm,
            auth: auth,
            onDismissNav: { dismiss() },
            onDisbandGroup: { Task { await disbandGroup() } }
        ))
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
    }

    // MARK: - ChatView Actions wiring

    private var chatViewActions: ChatView.Actions {
        var a = ChatView.Actions()
        a.onSend = { Task { await vm.send() } }
        a.onDoubleTapHeart = { msg in
            Haptics.impact(.light)
            vm.applyOptimisticReaction(messageId: msg.id, emoji: "❤️", myLogin: auth.login)
            Task { try? await APIClient.shared.react(messageId: msg.id, emoji: "❤️", add: true) }
        }
        a.onReact = { msg, emoji in
            Haptics.impact(.light)
            vm.applyOptimisticReaction(messageId: msg.id, emoji: emoji, myLogin: auth.login)
            AnalyticsTracker.trackReaction(emoji: emoji)
            Task { try? await APIClient.shared.react(messageId: msg.id, emoji: emoji, add: true) }
        }
        a.onMoreReactions = { msg in reactingFor = msg }
        a.onReply = { msg in
            vm.replyingTo = msg
            vm.editingMessage = nil
        }
        a.onCopyText = { msg in
            UIPasteboard.general.string = msg.content
            ClipboardWatcher.markSelfOriginWrite()
            ToastCenter.shared.show(.success, "Copied")
        }
        a.onCopyImage = { msg in
            guard let urls = Self.imageAttachmentURLs(msg),
                  let first = urls.first,
                  let url = URL(string: first) else { return }
            Task { await Self.copyImageToPasteboard(url: url) }
        }
        a.onSaveToPhotos = { msg in
            guard let urls = Self.imageAttachmentURLs(msg),
                  let first = urls.first,
                  let url = URL(string: first) else { return }
            Task { await ImageDownloader.saveToPhotos(url: url) }
        }
        a.onTogglePin = { msg in Task { await vm.togglePin(msg) } }
        a.onForward = { msg in showForward = msg }
        a.onSeenBy = { msg in seenByFor = msg }
        a.onEdit = { msg in vm.startEdit(msg) }
        a.onUnsend = { msg in confirmUnsend = msg }
        a.onDelete = { msg in confirmDelete = msg }
        a.onReport = { msg in reportingMessage = msg }
        a.onReactionsTap = { msg in reactorsFor = msg }
        a.onReplyPreviewTap = { msg in jumpToReply(from: msg) }
        a.onAttachmentTap = { msg, url in
            let urls = (msg.attachments?.map(\.url) ?? [msg.attachment_url].compactMap { $0 })
            if let start = urls.firstIndex(of: url) {
                // Warm the 2048px cache for the tapped image (and
                // its immediate neighbours) before presenting the
                // viewer. Without this, the zoom transition plays
                // while the destination is still downsampling the
                // full-res variant — the grid tile was cached at
                // 800px, so the viewer key misses and the push
                // starts on an empty frame. Prefetching here gives
                // the transition solid content to morph into.
                let nearby = Set([start, start - 1, start + 1])
                    .filter { $0 >= 0 && $0 < urls.count }
                    .compactMap { URL(string: urls[$0]) }
                if !nearby.isEmpty {
                    ImageCache.shared.prefetch(urls: nearby, maxPixelSize: 2048)
                }
                imagePreview = ImagePreviewState(urls: urls, index: start)
            }
        }
        a.onPinBadgeTap = { _ in showPinned = true }
        a.onAvatarTap = { login in
            profileRoute = ProfileLoginRoute(login: login)
        }
        a.onInsertMention = { p in insertMention(p.login) }
        a.onClipboardPaste = { img in
            Haptics.impact(.light)
            pendingDropImages = [img]
            showDropConfirm = true
            clipboard.consume()
        }
        a.onClipboardDismiss = { clipboard.dismiss() }
        a.onMacCatalystSubmit = {
            Task { await vm.send() }
        }
        a.onRetryPending = { message in
            guard let pending = OutboxStore.shared.pending(
                conversationID: vm.conversation.id,
                localID: message.id
            ) else {
                // Race: pending was discarded between menu render and tap.
                // Surface a hint so the user isn't left wondering.
                ToastCenter.shared.show(.info, "Already removed")
                return
            }
            OutboxStore.shared.retry(pending)
        }
        a.onDiscardPending = { message in
            OutboxStore.shared.discard(
                conversationID: vm.conversation.id,
                localID: message.id
            )
        }
        return a
    }

    // MARK: - Toolbar

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

    // MARK: - Reply pulse

    private func jumpToReply(from msg: Message) {
        guard let targetId = msg.reply?.id else { return }
        Task {
            let found = await vm.ensureMessageLoaded(id: targetId)
            guard found else { return }
            pendingJumpId = targetId
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.easeInOut(duration: 0.25)) { pulsingId = targetId }
            try? await Task.sleep(nanoseconds: 600_000_000)
            withAnimation(.easeInOut(duration: 0.3)) { pulsingId = nil }
        }
    }

    // MARK: - Drop preview + Catalyst drag-drop

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
            if provider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { obj, _ in
                    if let img = obj as? UIImage { append(img) }
                    group.leave()
                }
                continue
            }

            let types = provider.registeredTypeIdentifiers
            let imageTypes = ["public.jpeg", "public.png", "public.heic", "public.image"]
            if let uti = types.first(where: { imageTypes.contains($0) }) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: uti) { data, _ in
                    if let data, let img = UIImage(data: data) { append(img) }
                    group.leave()
                }
                continue
            }

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
        guard !images.isEmpty else { return }
        Task { await vm.uploadImagesAndSend(images: images, senderLogin: auth.login) }
    }

    /// Copy an image message to the system pasteboard using the raw
    /// compressed bytes (PNG / JPEG / GIF / HEIC as-received) rather
    /// than `UIPasteboard.general.image = img`.
    ///
    /// Why not the `.image =` setter:
    /// - It serialises the decoded `UIImage` through `NSItemProvider`
    ///   for cross-process handoff. Camera-sized photos routinely
    ///   produce 48MB+ decoded bitmaps; serialising that crashes
    ///   memory-constrained devices with OOM / uncatchable Obj-C
    ///   exceptions.
    /// - `ImageCache.load()` returns a UIImage rebuilt by
    ///   `UIGraphicsImageRenderer`; attaching that synthesised image
    ///   to the pasteboard has been flaky compared to shipping the
    ///   original bytes.
    /// - Animated GIFs get silently flattened to the first frame
    ///   via `UIImage` — raw-bytes path preserves the animation.
    ///
    /// Where the bytes come from:
    /// `ImageCache.rawData(for:)` is a memory-cached view of the
    /// original network bytes. `ImageCache.load()` (the path that
    /// populates every bubble's displayed image) stashes bytes into
    /// that cache on every download, so anything the user has seen
    /// in the chat is a 0-latency memory hit here. Cold miss falls
    /// back to disk cache, then network. `setData(_:forPasteboardType:)`
    /// never re-encodes a decoded bitmap.
    private static func copyImageToPasteboard(url: URL) async {
        guard let data = await ImageCache.shared.rawData(for: url), !data.isEmpty else {
            await MainActor.run {
                ToastCenter.shared.show(.error, "Couldn't copy image")
            }
            return
        }
        let type = pasteboardUTI(for: data, url: url)
        await MainActor.run {
            UIPasteboard.general.setData(data, forPasteboardType: type)
            // Tell every ClipboardWatcher in the app that this write
            // came from us so their notification handlers skip the
            // main-thread decode + PNG-hash path. Without this the
            // second+ copy of the same image stalls ~200–500ms on
            // memory-constrained devices.
            ClipboardWatcher.markSelfOriginWrite()
            ToastCenter.shared.show(.success, "Image copied")
        }
    }

    /// Sniff the image format from magic bytes first, then fall back
    /// to the URL's path extension. `public.image` is a safe generic
    /// type accepted by receiving apps when the sniff finds nothing.
    private static func pasteboardUTI(for data: Data, url: URL) -> String {
        if data.count >= 12 {
            let b = [UInt8](data.prefix(12))
            if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "public.png" }
            if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "public.jpeg" }
            if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "com.compuserve.gif" }
            // RIFF....WEBP
            if b.starts(with: [0x52, 0x49, 0x46, 0x46]) && b.count >= 12 &&
               b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 {
                return "org.webmproject.webp"
            }
            // HEIC / HEIF: `....ftypheic` / `....ftypmif1` / `....ftypheix`
            if b.count >= 12 && b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 {
                return "public.heic"
            }
        }
        switch url.pathExtension.lowercased() {
        case "png": return "public.png"
        case "jpg", "jpeg": return "public.jpeg"
        case "gif": return "com.compuserve.gif"
        case "webp": return "org.webmproject.webp"
        case "heic": return "public.heic"
        case "heif": return "public.heif"
        default: return "public.image"
        }
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

    // MARK: - PhotosPicker routing

    @MainActor
    private func routePickedPhotos(_ newItems: [PhotosPickerItem]) async {
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

    // MARK: - Lifecycle

    private func onAppearTask() async {
        socket.currentConversationId = vm.conversation.id
        ActiveConversationTracker.shared.id = vm.conversation.id
        await vm.load()
        socket.subscribe(conversation: vm.conversation.id)
        // Receive server-confirmed self-sends directly from OutboxStore
        // (so a successful send is visible even if the socket event for
        // it never arrives — e.g. WS disconnect, local API without WS).
        // Same dedup contract as the socket handler below.
        OutboxStore.shared.registerDeliveryHandler(conversationID: vm.conversation.id) { msg in
            guard ChatMessageView.seenIds.insert(msg.id).inserted else { return }
            vm.messages.append(msg)
        }
        socket.onMessageSent = { msg in
            guard msg.conversation_id == vm.conversation.id else { return }
            // Dedup using the atomic Set insert: the only way a second
            // callback for the same id can race past the .contains guard
            // is if both fire close together off the socket queue. Set
            // insert returns false on the second call, dropping it cleanly.
            guard ChatMessageView.seenIds.insert(msg.id).inserted else { return }
            vm.messages.append(msg)
            if msg.sender != auth.login {
                Task { try? await APIClient.shared.markRead(conversationId: vm.conversation.id) }
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

    private func syncMutedFromCache() {
        guard let fresh = ConversationsCache.shared.get()?.first(where: { $0.id == vm.conversation.id }) else { return }
        vm.conversation = fresh
        vm.isMuted = fresh.is_muted == true
    }

    private func onDisappearCleanup() {
        OutboxStore.shared.unregisterDeliveryHandler(conversationID: vm.conversation.id)
        socket.unsubscribe(conversation: vm.conversation.id)
        socket.emitTyping(conversationId: vm.conversation.id, isTyping: false)
        if socket.currentConversationId == vm.conversation.id {
            socket.currentConversationId = nil
            ActiveConversationTracker.shared.id = nil
        }
    }
}

// MARK: - Sheets modifier (keeps chatShell's body under the expression type-check budget)

private struct ChatDetailSheets: ViewModifier {
    @Binding var showSearch: Bool
    @Binding var showPinned: Bool
    @Binding var showForward: Message?
    @Binding var imagePreview: ImagePreviewState?
    @Binding var profileRoute: ProfileLoginRoute?
    @Binding var webURL: URL?
    @Binding var reactingFor: Message?
    @Binding var seenByFor: Message?
    @Binding var reactorsFor: Message?
    @Binding var showMembers: Bool
    @Binding var showAddMember: Bool
    @Binding var reportingMessage: Message?
    @Binding var showReportConfirm: Bool
    @Binding var confirmDelete: Message?
    @Binding var confirmUnsend: Message?
    @Binding var showLeaveConfirm: Bool
    @Binding var showInviteLink: Bool
    @Binding var showGroupSettings: Bool
    @Binding var showDeleteGroupConfirm: Bool
    @Binding var pendingJumpId: String?
    @Binding var reportReason: String
    @Binding var reportDetail: String
    @ObservedObject var vm: ChatViewModel
    let auth: AuthStore
    let onDismissNav: () -> Void
    let onDisbandGroup: () -> Void

    func body(content: Content) -> some View {
        content
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
            // Image viewer handled by .navigationDestination(item:)
            // on the chat shell so iOS 18+ can run the zoom
            // transition (matchedTransitionSource on the tile →
            // navigationTransition(.zoom(...)) on the destination).
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
            .modifier(LeaveGroupAlert(show: $showLeaveConfirm, conversation: vm.conversation, onLeave: onDismissNav))
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
                        participants: vm.conversation.participantsOrEmpty
                            + [vm.conversation.other_user].compactMap { $0 },
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
                    // Tell the list to patch its row too — BE's
                    // conversation:updated sometimes lags, which leaves
                    // the list showing a stale avatar for a long time.
                    NotificationCenter.default.post(
                        name: .gitchatConversationMetadataChanged,
                        object: nil,
                        userInfo: [
                            "id": vm.conversation.id,
                            "name": newName as Any,
                            "avatarUrl": newAvatarUrl as Any,
                        ]
                    )
                    Task { await vm.load() }
                },
                onDeleteConfirmed: onDisbandGroup
            ))
            .sheet(item: $reportingMessage) { msg in
                ReportMessageSheet(
                    message: msg,
                    reason: $reportReason,
                    detail: $reportDetail,
                    onSubmit: {
                        Task {
                            try? await APIClient.shared.reportMessage(
                                messageId: msg.id,
                                reason: reportReason,
                                detail: reportDetail.isEmpty ? nil : reportDetail
                            )
                            BlockStore.shared.block(msg.sender)
                            reportReason = "Spam"
                            reportDetail = ""
                            reportingMessage = nil
                            showReportConfirm = true
                        }
                    },
                    onCancel: { reportingMessage = nil }
                )
            }
            .alert("Thanks — we'll review it within 24 hours.", isPresented: $showReportConfirm) {
                Button("OK", role: .cancel) {}
            }
    }
}

// MARK: - Report sheet extracted to its own type

private struct ReportMessageSheet: View {
    let message: Message
    @Binding var reason: String
    @Binding var detail: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("What's wrong?") {
                    Picker("Reason", selection: $reason) {
                        Text("Spam").tag("Spam")
                        Text("Harassment").tag("Harassment")
                        Text("Hate speech").tag("Hate")
                        Text("Sexual content").tag("Sexual")
                        Text("Violence or self-harm").tag("Violence")
                        Text("Other").tag("Other")
                    }
                }
                Section("Details (optional)") {
                    TextEditor(text: $detail)
                        .frame(minHeight: 80)
                }
                Section {
                    Button(action: onSubmit) {
                        HStack { Spacer(); Text("Report and block").bold(); Spacer() }
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Report message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

// MARK: - Image viewer destination modifier

/// Presents the image viewer.
///
/// - iOS 18+: pushes via `navigationDestination(item:)` and attaches
///   the native zoom transition (iOS Photos gallery-style —
///   `matchedTransitionSource` on the tile → `navigationTransition(.zoom)`
///   on the destination).
/// - iOS 17 and earlier: falls back to `.fullScreenCover`. The zoom
///   transition only exists on iOS 18, and navigationDestination(item:)
///   without it would just be a plain horizontal push, which feels
///   worse than the cover's cross-dissolve for a photo viewer.
private struct ImageViewerDestinationModifier: ViewModifier {
    @Binding var imagePreview: ImagePreviewState?
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macCatalyst 18.0, *) {
            content.navigationDestination(item: $imagePreview) { state in
                zoomDestination(for: state)
            }
        } else {
            content.fullScreenCover(item: $imagePreview) { state in
                ImageViewerSheet(urls: state.urls, startIndex: state.index)
            }
        }
    }

    @available(iOS 18.0, macCatalyst 18.0, *)
    @ViewBuilder
    private func zoomDestination(for state: ImagePreviewState) -> some View {
        let currentURL = state.index < state.urls.count
            ? state.urls[state.index]
            : state.urls.first ?? ""
        ImageViewerSheet(urls: state.urls, startIndex: state.index)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .navigationTransition(
                .zoom(sourceID: "chat.image:\(currentURL)", in: namespace)
            )
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
