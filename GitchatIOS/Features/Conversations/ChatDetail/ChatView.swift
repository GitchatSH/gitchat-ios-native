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
    @Binding var pendingClipboardImage: UIImage?
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

    /// Imperative actions wired from the caller.
    struct Actions {
        var onSend: () -> Void = {}
        var onDoubleTapHeart: (Message) -> Void = { _ in }
        var onReact: (Message, String) -> Void = { _, _ in }
        var onMoreReactions: (Message) -> Void = { _ in }
        var onReply: (Message) -> Void = { _ in }
        var onCopyText: (Message) -> Void = { _ in }
        var onCopyImage: (Message) -> Void = { _ in }
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
        var onClipboardPaste: (UIImage) -> Void = { _ in }
        var onClipboardDismiss: () -> Void = {}
        var onMacCatalystSubmit: () -> Void = {}
        var onRetryPending: (Message) -> Void = { _ in }
        var onDiscardPending: (Message) -> Void = { _ in }
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
    @State private var pinnedBannerDismissed = false
    @StateObject private var swipeState = ChatSwipeState()
    /// Count of new messages that arrived while the user was scrolled up.
    /// Incremented when `isAtBottom == false` and a new message appears;
    /// reset to 0 when the user scrolls back to the bottom.
    @State private var newWhileScrolledUp: Int = 0
    @State private var newMentionsWhileScrolledUp: Int = 0
    /// IDs of messages containing @mention that arrived while scrolled up (for jump-to-mention).
    @State private var pendingMentionIds: [String] = []

    // MARK: Body

    var body: some View {
        ZStack {
            ChatBackground()
                .ignoresSafeArea()
            VStack(spacing: 0) {
                pinnedBanner
                list
                if let login = blockedBannerLogin {
                    blockedBanner(login: login)
                } else if composerVisible {
                    composerStack
                }
            }
            #if targetEnvironment(macCatalyst)
            // Detail column on Catalyst is wide — bubbles + composer
            // hugging the edges reads as "unfinished layout". Inset
            // them so content has breathing room while the background
            // keeps extending edge-to-edge.
            .padding(.horizontal, 16)
            #endif
        }
        .overlay { menuOverlay }
        .environment(\.chatTheme, .default)
        // Reset "new while scrolled" counters when the user scrolls back to bottom.
        .onChange(of: isAtBottom) { atBottom in
            if atBottom {
                newWhileScrolledUp = 0
                newMentionsWhileScrolledUp = 0
                pendingMentionIds.removeAll()
            }
        }
        // Track new messages arriving while scrolled up.
        .onChange(of: visibleMessages.count) { newCount in
            guard !isAtBottom, newCount > 0 else { return }
            // The newest message is at index 0 (rotated list).
            let newest = visibleMessages[0]
            // Only count messages from OTHER users (own sends auto-scroll).
            guard newest.sender != myLogin else { return }
            newWhileScrolledUp += 1
            if let login = myLogin, newest.content.localizedCaseInsensitiveContains("@\(login)") {
                newMentionsWhileScrolledUp += 1
                pendingMentionIds.append(newest.id)
            }
        }
    }

    // MARK: Pinned banner

    @ViewBuilder
    private var pinnedBanner: some View {
        if vm.conversation.isGroup && !vm.pinnedIds.isEmpty && !pinnedBannerDismissed {
            let pinned = visibleMessages.filter { vm.pinnedIds.contains($0.id) }
            if !pinned.isEmpty {
                PinnedBannerView(
                    pinnedMessages: pinned,
                    onTap: { msg in pendingJumpId = msg.id },
                    onDismiss: { pinnedBannerDismissed = true }
                )
            }
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
                showSeen: showSeen,
                seenAvatarURL: seenAvatarURL,
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
                unreadCount: {
                    let readAt = vm.readCursors[myLogin ?? ""] ?? vm.otherReadAt
                    return visibleMessages.filter { ($0.created_at ?? "") > (readAt ?? "") }.count
                }(),
                myReadAt: vm.readCursors[myLogin ?? ""] ?? vm.otherReadAt,
                cellBuilder: { msg, idx in
                    messageRow(for: msg, at: idx)
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
            // Tail on the last message in a same-sender group. In the
            // rotated table, idx-1 is the NEWER message (visually below).
            // Show tail when the next visual message has a different sender.
            let showTail: Bool = {
                guard idx > 0 else { return true } // newest message always has tail
                let next = visibleMessages[idx - 1]
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
                .padding(.top, showHeader ? 20 : 4)
                .chatSwipeToReply(isMe: isMe, messageId: msg.id)
                .onTapGesture(count: 2) { actions.onDoubleTapHeart(msg) }
                if !cursors.isEmpty {
                    seenByAvatarsRow(cursors: cursors, isMe: isMe, for: msg)
                }
            }
        }
    }

    @ViewBuilder
    private func seenByAvatarsRow(cursors: [String], isMe: Bool, for msg: Message) -> some View {
        HStack(spacing: 0) {
            if isMe { Spacer() }
            let shown = Array(cursors.prefix(10))
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
            .padding(isMe ? .trailing : .leading, isMe ? 6 : 36)
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
            if !mentionSuggestions.isEmpty {
                ChatMentionSuggestionRow(
                    suggestions: mentionSuggestions,
                    onPick: { actions.onInsertMention($0) }
                )
            }
            if let img = pendingClipboardImage {
                ChatClipboardChip(
                    image: img,
                    onPaste: { actions.onClipboardPaste(img) },
                    onDismiss: { actions.onClipboardDismiss() }
                )
            }
            ChatInputView(
                draft: $vm.draft,
                photoItems: $photoItems,
                mode: composerMode,
                isUploading: vm.uploading,
                onSend: actions.onSend,
                onSubmitMacCatalyst: actions.onMacCatalystSubmit,
                focusProxy: focusProxy
            )
        }
        .overlay(alignment: .topTrailing) {
            // Jump-button stack: @mention + scroll-to-bottom with
            // unread badge. Animation is scoped here so the composer
            // doesn't re-render on every isAtBottom flip.
            JumpButtonStack(
                isAtBottom: isAtBottom,
                unreadCount: jumpUnreadCount,
                mentionCount: jumpMentionCount,
                onJumpToBottom: { scrollToBottomToken &+= 1 },
                onJumpToMention: {
                    if let firstMention = pendingMentionIds.first {
                        pendingJumpId = firstMention
                    } else {
                        scrollToBottomToken &+= 1
                    }
                }
            )
            .padding(.trailing, 6)
            .offset(y: -52)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var composerMode: ChatInputView.Mode {
        if vm.editingMessage != nil { return .editing }
        if vm.replyingTo != nil { return .replying }
        return .message
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
        ChatMessageView(
            message: t.message,
            isMe: t.isMe,
            myLogin: myLogin,
            resolvedAvatar: resolveAvatar(t.message),
            showHeader: true,
            isPinned: vm.pinnedIds.contains(t.message.id),
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
