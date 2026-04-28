import SwiftUI
import PhotosUI
import UIKit

/// Top-level Chat surface — the message list + composer + menu
/// overlay + keyboard-aware bottom inset, all composed. Caller
/// (ChatDetailView) owns navigation, sheets, and the view model; this
/// view is the reusable "chat screen body" with a clean external
/// contract.
///
/// Design choices:
/// - Owns a `KeyboardState` so the composer's bottom inset tracks the
///   keyboard with matching duration + curve.
/// - Owns the `menuTarget` state driving the `MessageMenu` overlay so
///   long-press is fully self-contained.
/// - All message operations (send / react / reply / pin / forward /
///   edit / unsend / delete / report / copy / copy-image / seen-by)
///   are exposed as closures in `Actions` so the owner stays in
///   charge of sheet presentation + API wiring.
struct ChatView: View {
    @Environment(\.chatTheme) private var theme

    // MARK: External contract

    @ObservedObject var vm: ChatViewModel
    let myLogin: String?
    let visibleMessages: [Message]
    let showSeen: Bool
    let seenAvatarURL: String?
    @Binding var pulsingId: String?
    @Binding var pendingJumpId: String?
    @Binding var isAtBottom: Bool
    @Binding var scrollToBottomToken: Int
    @Binding var photoItems: [PhotosPickerItem]
    @Binding var composerVisible: Bool
    /// Namespace owned by the host view (ChatDetailView) and used for
    /// the image viewer's zoom transition. Threaded through the cell
    /// builder so each attachment tile can mark itself as the
    /// `matchedTransitionSource` for the push.
    let imageZoomNamespace: Namespace.ID?

    let mentionSuggestions: [ConversationParticipant]
    let resolveAvatar: (Message) -> String?
    let seenByLogins: (Message) -> [String]
    let seenCursorLogins: (Message, String?) -> [String]
    let participants: [ConversationParticipant]
    let blockedBannerLogin: String?
    let onUnblock: (String) -> Void
    var totalUnreadCount: Int = 0

    /// Imperative actions wired from the caller.
    struct Actions {
        var onSend: () -> Void = {}
        var onDoubleTapHeart: (Message) -> Void = { _ in }
        var onReact: (Message, String) -> Void = { _, _ in }
        var onMoreReactions: (Message) -> Void = { _ in }
        var onReply: (Message) -> Void = { _ in }
        var onCopyText: (Message) -> Void = { _ in }
        var onCopyImage: (Message) -> Void = { _ in }
        var onSaveToPhotos: (Message) -> Void = { _ in }
        var onTogglePin: (Message) -> Void = { _ in }
        var onForward: (Message) -> Void = { _ in }
        var onSeenBy: (Message) -> Void = { _ in }
        var onEdit: (Message) -> Void = { _ in }
        var onUnsend: (Message) -> Void = { _ in }
        var onDelete: (Message) -> Void = { _ in }
        var onReport: (Message) -> Void = { _ in }
        var onReactionsTap: (Message) -> Void = { _ in }
        var onReplyPreviewTap: (Message) -> Void = { _ in }
        var onAttachmentTap: (Message, String) -> Void = { _, _ in }
        var onPinBadgeTap: (Message) -> Void = { _ in }
        var onAvatarTap: (String) -> Void = { _ in }
        var onInsertMention: (ConversationParticipant) -> Void = { _ in }
        var onPasteImage: (UIImage) -> Void = { _ in }
        var onMacCatalystSubmit: () -> Void = {}
        var onShowPinnedList: () -> Void = {}
        var onRetryPending: (Message) -> Void = { _ in }
        var onDiscardPending: (Message) -> Void = { _ in }
        var onBack: () -> Void = {}
        var onHeaderTap: () -> Void = {}
        /// Builds the header menu content. Caller provides Menu items.
        var headerMenuContent: AnyView = AnyView(EmptyView())
    }

    let actions: Actions

    /// Focus proxy — owner calls `.focus()` after a Reply action so
    /// the composer becomes first responder without leaking
    /// `@FocusState` through the contract.
    @StateObject private var focusProxy = ChatInputView.FocusProxy()

    // MARK: Internal state

    @StateObject private var keyboard = KeyboardState()
    @State private var menuTarget: MessageMenuTarget?
    @State private var firstVisibleDate: Date?
    @StateObject private var swipeState = ChatSwipeState()
    /// Count of new messages that arrived while the user was scrolled up.
    /// Incremented when `isAtBottom == false` and a new message appears;
    /// reset to 0 when the user scrolls back to the bottom.
    @State private var newWhileScrolledUp: Int = 0
    @State private var newMentionsWhileScrolledUp: Int = 0
    /// IDs of messages containing @mention that arrived while scrolled up (for jump-to-mention).
    @State private var pendingMentionIds: [String] = []
    /// IDs of messages with new reactions that arrived while scrolled up.
    @State private var pendingReactionIds: [String] = []

    // MARK: Body

    /// Composer height measured via GeometryReader, fed to the list
    /// as contentInset so messages scroll behind the frosted overlay.
    @State private var composerOverlayHeight: CGFloat = 0
    @State private var bannerOverlayHeight: CGFloat = 0

    // MARK: Composer link preview
    @State private var dismissedPreviewURLs: Set<String> = []
    @State private var detectedDraftURL: URL?

    /// Direct bridge to UITableView for scroll commands, bypassing
    /// SwiftUI's updateUIView cycle which races with preference updates.
    @StateObject private var scrollProxy = ChatScrollProxy()

    var body: some View {
        ZStack {
            ChatBackground()
                .ignoresSafeArea()

            // Message list — FULL SCREEN. No VStack wrapping.
            // contentInset on the UITableView pushes content away
            // from overlays while allowing scroll-behind for blur.
            // Gradient mask fades bubbles out at top/bottom edges
            // so they blur into the header/composer overlays.
            list
                .ignoresSafeArea()
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: bannerOverlayHeight + 20)

                        Rectangle().fill(.black)

                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: composerOverlayHeight * 0.5)
                    }
                }

            // Header + Pinned banner overlay — top
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    chatHeader
                    pinnedBanner
                }
                .background {
                    LinearGradient(
                        colors: [
                            Color(.systemBackground),
                            Color(.systemBackground).opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(.container, edges: .top)
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: BannerHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
                Spacer()
            }

            // Composer overlay — bottom
            VStack(spacing: 0) {
                Spacer()
                if let login = blockedBannerLogin {
                    blockedBanner(login: login)
                } else if composerVisible {
                    composerStack
                        .background {
                            Group {
                                if showingLinkPreview {
                                    Color(.systemBackground)
                                } else {
                                    LinearGradient(
                                        colors: [
                                            Color(.systemBackground).opacity(0),
                                            Color(.systemBackground)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                }
                            }
                            .ignoresSafeArea(.container, edges: .bottom)
                        }
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ComposerHeightKey.self,
                                    value: geo.size.height + geo.safeAreaInsets.bottom + 8
                                )
                            }
                        )
                }
            }
        }
        .onPreferenceChange(ComposerHeightKey.self) { composerOverlayHeight = $0 }
        .onPreferenceChange(BannerHeightKey.self) { bannerOverlayHeight = $0 }
        #if targetEnvironment(macCatalyst)
        .padding(.horizontal, 16)
        #endif
        .overlay { menuOverlay }
        .environment(\.chatTheme, .default)
        // Reset "new while scrolled" counters when the user scrolls back to bottom.
        .onChange(of: isAtBottom) { atBottom in
            if atBottom {
                newWhileScrolledUp = 0
                // Only clear mention/reaction when user manually scrolls to bottom,
                // not on initial load. They persist until user taps through them.
            }
        }
        // Track new messages arriving while scrolled up.
        .onChange(of: visibleMessages.last?.id) { _ in
            guard !isAtBottom else { return }
            guard let newest = visibleMessages.last else { return }
            // Only count messages from OTHER users (own sends auto-scroll).
            guard newest.sender != myLogin else { return }
            newWhileScrolledUp += 1
            if let login = myLogin, newest.content.localizedCaseInsensitiveContains("@\(login)") {
                newMentionsWhileScrolledUp += 1
                pendingMentionIds.append(newest.id)
            }
            // Track reactions on own messages
            if newest.sender == myLogin,
               let reactions = newest.reactions, !reactions.isEmpty {
                pendingReactionIds.append(newest.id)
            }
        }
        .onChange(of: vm.draft) { newDraft in
            let trimmed = newDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                dismissedPreviewURLs.removeAll()
                if detectedDraftURL != nil {
                    withAnimation(.easeInOut(duration: 0.2)) { detectedDraftURL = nil }
                }
                return
            }
            let url = ChatMessageText.firstURL(in: newDraft)
            if url?.absoluteString != detectedDraftURL?.absoluteString {
                withAnimation(.easeInOut(duration: 0.2)) {
                    detectedDraftURL = url
                }
            }
        }
    }

    // MARK: Chat header (custom nav bar replacement)

    #if !targetEnvironment(macCatalyst)
    @ViewBuilder
    private var chatHeader: some View {
        HStack(spacing: 8) {
            Button { actions.onBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .modifier(GlassCircle())
                    .overlay(alignment: .topTrailing) {
                        if totalUnreadCount > 0 {
                            Text(totalUnreadCount > 99 ? "99+" : "\(totalUnreadCount)")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 22, minHeight: 22)
                                .background(Color("AccentColor"), in: Capsule())
                                .offset(x: 6, y: -6)
                        }
                    }
            }
            .buttonStyle(.plain)

            Spacer()

            ChatDetailTitleBar(
                conversation: vm.conversation,
                vm: vm,
                onTap: { actions.onHeaderTap() }
            )
            .padding(.horizontal, 44)
            .frame(height: 44)
            .modifier(GlassPill())

            Spacer()

            Menu {
                actions.headerMenuContent
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(.label))
                    .frame(width: 44, height: 44)
                    .modifier(GlassCircle())
            }
            .tint(.primary)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
    #else
    @ViewBuilder
    private var chatHeader: some View { EmptyView() }
    #endif

    // MARK: Pinned banner

    @ViewBuilder
    private var pinnedBanner: some View {
        if !vm.pinnedMessages.isEmpty {
            PinnedBannerView(
                pinnedMessages: vm.pinnedMessages,
                onTap: { msg in
                    pendingJumpId = msg.id
                    Task {
                        _ = await vm.ensureMessageLoaded(id: msg.id, createdAt: msg.created_at)
                    }
                },
                onShowList: { actions.onShowPinnedList() }
            )
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if vm.isLoading && visibleMessages.isEmpty {
            ChatSkeleton()
        } else {
            ChatMessagesList(
                items: visibleMessages,
                typingUsers: Array(vm.typingUsers),
                isGroup: vm.conversation.isGroup,
                showSeen: false,
                seenAvatarURL: nil,
                pinnedIds: vm.pinnedIds,
                readCursors: vm.readCursors,
                pulsingId: pulsingId,
                scrollToId: pendingJumpId,
                isLoadingMore: vm.isLoadingMore,
                bottomInset: keyboard.height,
                scrollToBottomToken: scrollToBottomToken,
                scrollProxy: scrollProxy,
                composerHeight: composerOverlayHeight,
                jumpMentionCount: pendingMentionIds.count,
                jumpReactionCount: pendingReactionIds.count,
                onJumpToMention: {
                    guard !pendingMentionIds.isEmpty else { return nil }
                    let id = pendingMentionIds.removeFirst()
                    newMentionsWhileScrolledUp = max(0, newMentionsWhileScrolledUp - 1)
                    return id
                },
                onJumpToReaction: {
                    guard !pendingReactionIds.isEmpty else { return nil }
                    return pendingReactionIds.removeFirst()
                },
                isAtBottom: $isAtBottom,
                onScrollToIdConsumed: { pendingJumpId = nil },
                onTopReached: { Task { await vm.loadMoreIfNeeded() } },
                onCellLongPressed: { msg, frame in
                    menuTarget = MessageMenuTarget(
                        message: msg,
                        isMe: msg.sender == myLogin,
                        sourceFrame: frame
                    )
                },
                isMe: { $0.sender == myLogin },
                onReply: { actions.onReply($0) },
                swipeState: swipeState,
                onFirstVisibleDateChanged: { firstVisibleDate = $0 },
                composerOverlayHeight: composerOverlayHeight,
                bannerOverlayHeight: bannerOverlayHeight,
                unreadCount: {
                    let readAt = vm.readCursors[myLogin ?? ""] ?? vm.otherReadAt
                    return visibleMessages.filter { ($0.created_at ?? "") > (readAt ?? "") }.count
                }(),
                myReadAt: vm.readCursors[myLogin ?? ""] ?? vm.otherReadAt,
                cellBuilder: { msg, idx in
                    messageRow(for: msg, at: idx)
                },
                groupCellBuilder: { messages in
                    AnyView(groupedMessageRow(for: messages))
                }
            )
            .overlay(alignment: .top) {
                DatePillOverlay(date: firstVisibleDate)
                    .padding(.top, 8)
                    .animation(.easeInOut(duration: 0.2), value: firstVisibleDate)
            }
            .onTapGesture { focusProxy.blur() }
        }
    }

    @ViewBuilder
    private func messageRow(for msg: Message, at idx: Int) -> some View {
        if let t = msg.type, t != "user" {
            SystemMessageRow(message: msg) {
                if let target = msg.reply_to_id {
                    pendingJumpId = target
                }
            }
        } else {
            let prev = idx > 0 ? visibleMessages[idx - 1] : nil
            let showHeader = prev?.sender != msg.sender || (prev?.type ?? "user") != "user"
            let isMe = msg.sender == myLogin
            let nextCreatedAt: String? = (idx + 1 < visibleMessages.count) ? (visibleMessages[idx + 1].created_at ?? "") : nil
            let cursors = seenCursorLogins(msg, nextCreatedAt)
            // Tail + avatar on the LAST (newest) message in a same-sender
            // group. visibleMessages is sorted oldest-first. In the rotated
            // table, the newest message (highest idx) is visually at the
            // BOTTOM. Check if the NEXT message (idx+1 = newer = visually
            // below) has a different sender → this msg is the group's last.
            let showTail: Bool = {
                guard idx + 1 < visibleMessages.count else { return true }
                let next = visibleMessages[idx + 1]
                if let t = next.type, t != "user" { return true }
                return next.sender != msg.sender
            }()
            // Explicit VStack(spacing: 0) — without it, the two
            // sibling views (bubble + optional seen-by row) get
            // wrapped in a TupleView that UIHostingConfiguration
            // renders via an implicit stack with default spacing
            // (~8pt). That default was silently padding every row
            // that had a seen-by avatar, making same-sender spacing
            // "chỗ đúng chỗ sai" (right on bubbles without seen-by,
            // wrong on bubbles with it). Pinning to 0 makes the
            // vertical rhythm entirely owned by .padding(.top) below.
            let isFailed: Bool = {
                guard msg.id.hasPrefix("local-"),
                      let p = OutboxStore.shared.pending(conversationID: vm.conversation.id, localID: msg.id),
                      case .failed = p.state else { return false }
                return true
            }()
            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 4) {
                    ChatMessageView(
                        message: msg,
                        isMe: isMe,
                        myLogin: myLogin,
                        resolvedAvatar: resolveAvatar(msg),
                        showHeader: showHeader,
                        isPinned: vm.pinnedIds.contains(msg.id),
                        isPulsing: pulsingId == msg.id,
                        onReactionsTap: { actions.onReactionsTap(msg) },
                        onToggleReact: { emoji in actions.onReact(msg, emoji) },
                        onMoreReactions: { actions.onMoreReactions(msg) },
                        onReplyTap: { actions.onReplyPreviewTap(msg) },
                        onAttachmentTap: { url in actions.onAttachmentTap(msg, url) },
                        onPinTap: { actions.onPinBadgeTap(msg) },
                        onAvatarTap: { actions.onAvatarTap(msg.sender) },
                        imageMatchedNS: imageZoomNamespace,
                        showTail: showTail,
                        isGroup: vm.conversation.isGroup,
                        otherReadAt: vm.otherReadAt,
                        readCursors: vm.readCursors
                    )
                    .opacity(isFailed ? 0.6 : 1)
                    if isFailed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(.systemRed))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .onTapGesture { actions.onRetryPending(msg) }
                    }
                }
                .padding(.top, showHeader ? 8 : 4)
                .chatSwipeToReply(isMe: isMe, messageId: msg.id)
                .onTapGesture(count: 2) { actions.onDoubleTapHeart(msg) }
            }
        }
    }

    @ViewBuilder
    private func groupedMessageRow(for messages: [Message]) -> some View {
        let avatarURL = resolveAvatar(messages[0])
            ?? messages[0].sender_avatar
            ?? "https://github.com/\(messages[0].sender).png"
        let avatarLogin = messages[0].sender
        let groupId = "__group__|\(messages[0].id)"

        GroupedMessageRowInner(
            groupId: groupId,
            avatarURL: avatarURL,
            avatarLogin: avatarLogin,
            messages: messages,
            vm: vm,
            myLogin: myLogin,
            pulsingId: pulsingId,
            actions: actions,
            resolveAvatar: resolveAvatar,
            imageZoomNamespace: imageZoomNamespace
        )
    }
}

/// Extracted so it can read `StickyAvatarState` from the environment
/// (injected by `ChatMessagesList`'s Coordinator).
private struct GroupedMessageRowInner: View {
    let groupId: String
    let avatarURL: String
    let avatarLogin: String
    let messages: [Message]
    @ObservedObject var vm: ChatViewModel
    let myLogin: String?
    let pulsingId: String?
    let actions: ChatView.Actions
    let resolveAvatar: (Message) -> String?
    let imageZoomNamespace: Namespace.ID?

    @EnvironmentObject private var stickyState: StickyAvatarState

    var body: some View {
        let excess = stickyState.excess[groupId] ?? 0

        HStack(alignment: .bottom, spacing: 8) {
            // Avatar column — sticky: offset upward when the group
            // extends below the viewport (behind the composer).
            GeometryReader { geo in
                let maxOffset = max(0, geo.size.height - 32)
                let offset = min(excess, maxOffset)
                VStack {
                    Spacer()
                    AvatarView(url: avatarURL, size: 32, login: avatarLogin)
                        .frame(width: 32, height: 32)
                        .onTapGesture { actions.onAvatarTap(avatarLogin) }
                }
                .offset(y: -offset)
            }
            .frame(width: 32)

            // Bubbles column
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { idx, msg in
                    let isFirst = idx == 0
                    let isLast = idx == messages.count - 1
                    ChatMessageView(
                        message: msg,
                        isMe: false,
                        myLogin: myLogin,
                        resolvedAvatar: resolveAvatar(msg),
                        showHeader: isFirst,
                        isPinned: vm.pinnedIds.contains(msg.id),
                        isPulsing: pulsingId == msg.id,
                        onReactionsTap: { actions.onReactionsTap(msg) },
                        onToggleReact: { emoji in actions.onReact(msg, emoji) },
                        onMoreReactions: { actions.onMoreReactions(msg) },
                        onReplyTap: { actions.onReplyPreviewTap(msg) },
                        onAttachmentTap: { url in actions.onAttachmentTap(msg, url) },
                        onPinTap: { actions.onPinBadgeTap(msg) },
                        onAvatarTap: { actions.onAvatarTap(msg.sender) },
                        imageMatchedNS: imageZoomNamespace,
                        showTail: isLast,
                        isGroup: true,
                        isInsideGroup: true,
                        otherReadAt: vm.otherReadAt,
                        readCursors: vm.readCursors
                    )
                }
            }

            Spacer(minLength: 40)
        }
        .padding(.top, 8)
    }
}

extension ChatView {
    @ViewBuilder
    fileprivate func seenByAvatarsRow(cursors: [String], isMe: Bool, for msg: Message) -> some View {
        HStack(spacing: 0) {
            if isMe { Spacer() }
            let shown = Array(cursors.prefix(5))
            let extra = cursors.count - shown.count
            HStack(spacing: -4) {
                ForEach(shown, id: \.self) { login in
                    let p = participants.first { $0.login == login }
                    SeenAvatarWithTooltip(avatarURL: p?.avatar_url, name: p?.name ?? login)
                }
                if extra > 0 {
                    Text("+\(extra)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }
            }
            .padding(isMe ? .trailing : .leading, isMe ? 6 : 40)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture { actions.onSeenBy(msg) }
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            if !isMe { Spacer() }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: cursors)
    }

    // MARK: Composer stack (reply bar + mention chips + clipboard chip + composer)

    @ViewBuilder
    private var composerStack: some View {
        // Wrap the whole stack (reply bar / mention row / clipboard
        // chip / composer) in a VStack so the jump-to-bottom overlay
        // anchors above whichever row is currently topmost. Before,
        // the overlay was attached only to ChatInputView, so when a
        // reply bar appeared the button floated 52pt above the
        // composer — i.e. right on top of the reply preview.
        VStack(spacing: 0) {
            if vm.replyingTo != nil || vm.editingMessage != nil {
                ChatReplyEditBar(
                    editing: vm.editingMessage,
                    replyingTo: vm.replyingTo,
                    onDismiss: {
                        if vm.editingMessage != nil { vm.cancelEdit() }
                        else { vm.replyingTo = nil }
                    }
                )
            }
            if let previewURL = detectedDraftURL,
               !dismissedPreviewURLs.contains(previewURL.absoluteString) {
                ComposerLinkPreview(url: previewURL) {
                    dismissedPreviewURLs.insert(previewURL.absoluteString)
                    ComposerLinkPreview.suppressedURLs.insert(previewURL.absoluteString)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !mentionSuggestions.isEmpty {
                ChatMentionSuggestionRow(
                    suggestions: mentionSuggestions,
                    onPick: { actions.onInsertMention($0) }
                )
            }
            ChatInputView(
                draft: $vm.draft,
                photoItems: $photoItems,
                mode: composerMode,
                isUploading: vm.uploading,
                onSend: actions.onSend,
                onSubmitMacCatalyst: actions.onMacCatalystSubmit,
                onPasteImage: actions.onPasteImage,
                focusProxy: focusProxy
            )
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var composerMode: ChatInputView.Mode {
        if vm.editingMessage != nil { return .editing }
        if vm.replyingTo != nil { return .replying }
        return .message
    }

    private var showingLinkPreview: Bool {
        guard let url = detectedDraftURL else { return false }
        return !dismissedPreviewURLs.contains(url.absoluteString)
    }

    // MARK: Jump button computed counts

    /// Number of new messages that arrived while the user was scrolled up.
    /// Matches Telegram's behaviour: the badge counts messages you haven't
    /// scrolled to yet, not total-unread-in-conversation.
    private var jumpUnreadCount: Int {
        newWhileScrolledUp
    }

    /// Number of @-mentions that arrived while the user was scrolled up.
    private var jumpMentionCount: Int {
        newMentionsWhileScrolledUp
    }

    // MARK: Menu overlay

    @ViewBuilder
    private var menuOverlay: some View {
        if let t = menuTarget {
            MessageMenu(
                target: t,
                actions: visibleActions(for: t),
                currentReactions: currentUserReactions(for: t.message),
                seenCount: seenByLogins(t.message).count,
                seenLogins: seenByLogins(t.message),
                isReadByOthers: vm.isReadByOthers(for: t.message),
                participants: participants,
                onReact: { emoji in actions.onReact(t.message, emoji) },
                onMoreReactions: { actions.onMoreReactions(t.message) },
                onAction: { action in dispatch(action, for: t.message) },
                onDismiss: { menuTarget = nil },
                preview: {
                    repliedPreviewContent(for: t)
                }
            )
            .zIndex(100)
        }
    }

    /// Lifted bubble for the long-press menu. Since the inline reply
    /// quote now lives INSIDE the bubble (see `ChatMessageView`'s
    /// `textBubble`), a reply message is already a self-contained
    /// unit — we just render the same bubble the chat shows.
    @ViewBuilder
    private func repliedPreviewContent(for t: MessageMenuTarget) -> some View {
        let idx = visibleMessages.firstIndex(where: { $0.id == t.message.id })
        // showHeader: previous message has different sender
        let showHeader: Bool = {
            guard let idx, idx > 0 else { return true }
            let prev = visibleMessages[idx - 1]
            return prev.sender != t.message.sender || (prev.type ?? "user") != "user"
        }()
        // showTail: next message has different sender (or is last message)
        let showTail: Bool = {
            guard let idx, idx + 1 < visibleMessages.count else { return true }
            let next = visibleMessages[idx + 1]
            if let t = next.type, t != "user" { return true }
            return next.sender != t.message.sender
        }()
        return ChatMessageView(
            message: t.message,
            isMe: t.isMe,
            myLogin: myLogin,
            resolvedAvatar: resolveAvatar(t.message),
            showHeader: showHeader,
            isPinned: vm.pinnedIds.contains(t.message.id),
            showTail: showTail,
            isGroup: vm.conversation.isGroup,
            otherReadAt: vm.otherReadAt,
            readCursors: vm.readCursors
        )
    }

    private func visibleActions(for target: MessageMenuTarget) -> [MessageMenuAction] {
        let msg = target.message

        // Pending local messages get a reduced action set — server-side
        // operations (Reply, Pin, Forward, Edit, etc.) would 404 because
        // the message has no server id yet.
        if msg.id.hasPrefix("local-") {
            if let pending = OutboxStore.shared.pending(
                conversationID: vm.conversation.id,
                localID: msg.id
            ) {
                switch pending.state {
                case .sending:
                    // Allow Discard while still sending so a Task that hangs
                    // (e.g., URLSession stuck on a stalled connection) isn't
                    // a permanent dead-end for the user.
                    return [.discard]
                case .failed:
                    return [.retry, .discard]
                }
            }
            return []                        // unknown local- id (race) → no actions
        }

        let hasText = !msg.content.isEmpty
        let hasImage = (msg.attachments ?? []).contains { ($0.type == "image") || ($0.mime_type?.hasPrefix("image/") == true) }
            || (msg.attachment_url != nil)
        return MessageMenuAction.visibleActions(
            for: msg,
            isMe: target.isMe,
            isGroup: vm.conversation.isGroup,
            isPinned: vm.pinnedIds.contains(msg.id),
            hasText: hasText,
            hasImageAttachment: hasImage
        )
    }

    private func currentUserReactions(for msg: Message) -> Set<String> {
        guard let me = myLogin else { return [] }
        return Set(
            (msg.reactionRows ?? [])
                .filter { $0.user_login == me }
                .map { $0.emoji }
        )
    }

    private func dispatch(_ action: MessageMenuAction, for msg: Message) {
        switch action {
        case .reply:
            actions.onReply(msg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusProxy.focus()
            }
        case .copyText: actions.onCopyText(msg)
        case .copyImage: actions.onCopyImage(msg)
        case .saveToPhotos: actions.onSaveToPhotos(msg)
        case .pin, .unpin: actions.onTogglePin(msg)
        case .forward: actions.onForward(msg)
        case .seenBy: actions.onSeenBy(msg)
        case .edit:
            actions.onEdit(msg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusProxy.focus()
            }
        case .unsend: actions.onUnsend(msg)
        case .delete: actions.onDelete(msg)
        case .report: actions.onReport(msg)
        case .retry: actions.onRetryPending(msg)
        case .discard: actions.onDiscardPending(msg)
        }
    }

    // MARK: Blocked banner

    @ViewBuilder
    private func blockedBanner(login: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.secondary)
                Text("You blocked @\(login). Unblock to keep chatting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            Button { onUnblock(login) } label: {
                Text("Unblock")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(theme.replyAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(theme.blockedBannerBg)
    }
}

// MARK: - Preference key for composer overlay height

private struct ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BannerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

