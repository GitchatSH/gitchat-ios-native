import SwiftUI
import UIKit

// MARK: - Stable sender color hash

extension String {
    /// Stable DJB2 hash → index 0-6 for sender colors.
    /// Unlike String.hashValue, this is deterministic across app launches.
    var senderColorIndex: Int {
        let raw = self.utf8.reduce(5381) { ($0 &<< 5) &+ $0 &+ Int($1) }
        return ((raw % 7) + 7) % 7
    }

    var senderColor: Color {
        Color("SenderColor\(senderColorIndex + 1)")
    }
}

/// The chat bubble — one instance per message cell. Composition is
/// intentionally explicit: header avatar / sender / reply preview /
/// bubble content / pin badge / reactions row, each delegated to a
/// focused sub-view. The bubble itself renders attachments, the
/// forwarded-from header, text body with links + mentions, and a
/// link preview card when the body contains a URL.
///
/// State owned here:
/// - `appeared`: drives the first-time-only opacity fade so recycled
///   cells don't re-pop on scroll.
///
/// State owned by the cell factory (via callbacks):
/// - Reaction / reply / attachment / pin / avatar taps.
/// - Pulse highlight (`isPulsing`).
struct ChatMessageView: View {
    @Environment(\.chatTheme) private var theme

    // MARK: Inputs

    let message: Message
    let isMe: Bool
    var myLogin: String? = nil
    var resolvedAvatar: String? = nil
    var showHeader: Bool = true
    var isPinned: Bool = false
    var isPulsing: Bool = false
    var onReactionsTap: (() -> Void)? = nil
    var onToggleReact: ((String) -> Void)? = nil
    var onMoreReactions: (() -> Void)? = nil
    var onReplyTap: (() -> Void)? = nil
    var onAttachmentTap: ((String) -> Void)? = nil
    var onPinTap: (() -> Void)? = nil
    var onAvatarTap: (() -> Void)? = nil
    /// Namespace for the shared-element transition from attachment
    /// tile → full-screen image viewer. Passed through from the host
    /// ChatView.
    var imageMatchedNS: Namespace.ID? = nil
    /// URL currently shown in the viewer overlay. Used so only the
    /// tapped tile participates in the matchedGeometryEffect.
    var activeImagePreviewURL: String? = nil
    /// When true, the inline `ChatReplyPreview` is omitted from the
    /// bubble column. Used by the long-press menu so a reply
    /// message's lifted bubble matches the height of a normal-message
    /// preview (the menu's actions already let the user navigate to
    /// the quoted message via "Reply").
    var hideReplyPreview: Bool = false
    /// When true, a decorative tail is drawn at the bottom corner of the
    /// bubble (outgoing → trailing, incoming → leading). Shown on the
    /// last message in a same-sender group.
    var showTail: Bool = false
    /// Whether this conversation is a group chat.
    var isGroup: Bool = false
    /// When true, this bubble is rendered inside a grouped sender cell —
    /// the outer HStack with avatar/spacers is skipped because the group
    /// cell provides its own avatar column.
    var isInsideGroup: Bool = false
    /// DM: when the other user last read (ISO 8601 timestamp).
    var otherReadAt: String? = nil
    /// Group: per-login read timestamps.
    var readCursors: [String: String] = [:]

    // MARK: Local state

    @State private var appeared = false

    /// Session-wide set of message ids that have already materialized
    /// on screen — so the fade-in animation only fires the *first*
    /// time a bubble appears, not on every scroll recycle.
    /// Capped at 5000 entries to prevent unbounded memory growth.
    @MainActor static var seenIds: Set<String> = []

    @MainActor static func markSeen(_ ids: [String]) {
        seenIds.formUnion(ids)
        trimSeenIdsIfNeeded()
    }

    @MainActor private static func trimSeenIdsIfNeeded() {
        if seenIds.count > 5000 {
            // Drop roughly half — the set is unordered so we can't
            // pick "oldest", but trimming to 3000 amortizes the O(n)
            // cost across 2000 inserts. Worst case: a revisited old
            // bubble gets a redundant fade-in, which is harmless.
            let keep = Array(seenIds.prefix(3000))
            seenIds = Set(keep)
        }
    }

    // MARK: Body

    private var githubEventPayload: GitHubEventPayload? {
        GitHubEventPayload.tryParse(message.content)
    }

    var body: some View {
        if let payload = githubEventPayload {
            eventCardRow(payload: payload)
                .opacity(Self.seenIds.contains(message.id) || appeared ? 1 : 0)
                .onAppear(perform: onFirstAppear)
        } else if isInsideGroup {
            // Inside a grouped sender cell — just the bubble, no avatar/spacers.
            // The parent group cell provides the avatar column.
            bubbleColumn
                .opacity(Self.seenIds.contains(message.id) || appeared ? 1 : 0)
                .onAppear(perform: onFirstAppear)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if isMe {
                    Spacer(minLength: 40)
                } else if isGroup {
                    avatarColumn
                }
                bubbleColumn
                if !isMe { Spacer(minLength: 40) }
            }
            .opacity(Self.seenIds.contains(message.id) || appeared ? 1 : 0)
            .onAppear(perform: onFirstAppear)
        }
    }

    @ViewBuilder
    private func eventCardRow(payload: GitHubEventPayload) -> some View {
        GitHubEventCard(payload: payload, timestamp: message.shortTime)
            .padding(.horizontal, 16)
    }

    // MARK: Avatar column

    @ViewBuilder
    private var avatarColumn: some View {
        if isGroup {
            if showTail {
                AvatarView(
                    url: resolvedAvatar ?? message.sender_avatar,
                    size: 32,
                    login: message.sender
                )
                .frame(width: 32, height: 32)
                .contentShape(Rectangle().inset(by: -6))
                .onTapGesture { onAvatarTap?() }
                .instantTooltip("@\(message.sender)")
            } else {
                Color.clear.frame(width: 32, height: 32)
            }
        }
    }

    // MARK: Bubble column (header row / reply / bubble / reactions)

    @ViewBuilder
    private var bubbleColumn: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 0) {
            bubble
                .background(GeometryReader { geo in
                    Color.clear.onChange(of: geo.frame(in: .global)) { frame in
                        BubbleFrameCache.shared.set(frame, for: message.id)
                    }
                    .onAppear {
                        BubbleFrameCache.shared.set(geo.frame(in: .global), for: message.id)
                    }
                })
                .overlay(alignment: .topTrailing) { pinBadge }
                .scaleEffect(isPulsing ? 1.08 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isPulsing)
                .instantTooltip(ChatMessageText.fullTimestamp(message.created_at))
        }
    }

    private var myReactionEmojis: Set<String> {
        guard let me = myLogin else { return [] }
        return Set(
            (message.reactionRows ?? [])
                .filter { $0.user_login == me }
                .map { $0.emoji }
        )
    }

    // MARK: Read state

    private var isRead: Bool {
        guard isMe, let createdAt = message.created_at else { return false }
        // DM: other user read past this message
        if let otherReadAt = otherReadAt, otherReadAt >= createdAt { return true }
        // Group: any non-me cursor >= createdAt
        if let myLogin = myLogin {
            for (login, readAt) in readCursors where login != myLogin {
                if readAt >= createdAt { return true }
            }
        }
        return false
    }

    // MARK: Inline timestamp + checkmarks

    private var metaColor: Color {
        isMe ? theme.bubbleMetaOut : theme.bubbleMetaIn
    }

    private var timestampMeta: some View {
        HStack(spacing: 4) {
            if message.edited_at != nil {
                Text("edited")
                    .font(.caption)
                    .foregroundStyle(metaColor)
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(metaColor)
                    .rotationEffect(.degrees(45))
            }
            Text(message.shortTime ?? "")
                .font(.caption)
                .foregroundStyle(metaColor)

            if isMe, !message.id.hasPrefix("local-"), message.unsent_at == nil {
                doubleCheckView
            }
        }
        .fixedSize()
    }

    /// Timestamp for image-only messages — always white on dark overlay.
    private var imageTimestampMeta: some View {
        HStack(spacing: 4) {
            if message.edited_at != nil {
                Text("edited")
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(45))
            }
            Text(message.shortTime ?? "")
                .font(.caption)
                .foregroundStyle(.white)

            if isMe, !message.id.hasPrefix("local-"), message.unsent_at == nil {
                imageDoubleCheckView
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var imageDoubleCheckView: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isRead ? .white : .white.opacity(0.7))
            if isRead {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: 4)
            }
        }
        .frame(width: isRead ? 16 : 12, height: 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRead)
    }

    @ViewBuilder
    private var doubleCheckView: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isRead ? metaColor : metaColor.opacity(0.7))
            if isRead {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(metaColor)
                    .offset(x: 4)
            }
        }
        .frame(width: isRead ? 16 : 12, height: 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRead)
    }

    // MARK: Pin badge (removed — pin icon now inline with timestamp)

    @ViewBuilder
    private var pinBadge: some View {
        if false {
            Button { onPinTap?() } label: {
                Image(systemName: "pin.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(45))
                    .padding(5)
                    .background(theme.replyAccent, in: Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .offset(x: 10, y: -10)
        }
    }

    // MARK: Bubble content

    @ViewBuilder
    private var bubble: some View {
        if message.unsent_at != nil {
            unsentPlaceholder
        } else {
            textAndAttachmentBubble
        }
    }

    @ViewBuilder
    private var unsentPlaceholder: some View {
        Text("Message unsent")
            .italic()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.replyBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(.secondary)
    }

    private var isAttachmentOnly: Bool {
        let hasAttachment = (message.attachments != nil && !message.attachments!.isEmpty)
            || message.attachment_url != nil
        let hasText = !message.content.isEmpty
            || (message.reply != nil && !hideReplyPreview)
        return hasAttachment && !hasText
    }

    @ViewBuilder
    private var textAndAttachmentBubble: some View {
        if isAttachmentOnly {
            // Attachment-only: no text bubble, timestamp overlays the image
            attachmentContent
                .overlay(alignment: .bottomTrailing) {
                    imageTimestampMeta
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.4), in: Capsule())
                        .padding(6)
                }
        } else {
            // Has text (possibly with attachment): everything in one bubble
            textBubble
        }
    }

    /// In-bubble "Forwarded from @login" header row, rendered above the
    /// attachment when `parsed.forwardedFrom != nil`.
    @ViewBuilder
    private func forwardedHeader(from login: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.caption2.weight(.bold))
            Text("Forwarded from @\(login)")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(isMe ? .white.opacity(0.85) : .secondary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Compact reply quote styled to live INSIDE the bubble (same
    /// rounded container as the text). Mirrors the iMessage /
    /// Telegram look where the quoted snippet reads as a nested
    /// block, not a separate row above the bubble.
    ///
    /// The accent strip is an `.overlay` on the text VStack rather
    /// than a sibling in an HStack — a bare `RoundedRectangle.frame(width: 3)`
    /// (no height) expands vertically to fill whatever the parent
    /// offers, which in the menu preview context was a lot, and
    /// ballooned the quote block to an enormous square. Overlay
    /// gets height from the text column, so the strip is always
    /// exactly as tall as the content.
    @ViewBuilder
    private func inlineReplyQuote(for reply: ReplyPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let login = reply.sender_login {
                Text("@\(login)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isMe ? .white : theme.replyAccent)
            }
            Text(reply.body ?? "…")
                .font(.caption)
                .foregroundStyle(isMe ? .white.opacity(0.85) : .secondary)
                .lineLimit(2)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isMe ? .white : theme.replyAccent)
                .frame(width: 3)
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isMe ? Color.white.opacity(0.18) : Color(.tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { onReplyTap?() }
    }

    @ViewBuilder
    private func legacySingleAttachment(url: URL, urlString: String) -> some View {
        CachedAsyncImage(
            url: url,
            contentMode: .fit,
            placeholder: .filled,
            fitMaxWidth: 260,
            fitMaxHeight: 220
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .onTapGesture { onAttachmentTap?(urlString) }
    }

    /// Attachment content with its own clip (for standalone use).
    @ViewBuilder
    private var attachmentContent: some View {
        if let atts = message.attachments, !atts.isEmpty {
            ChatAttachmentsGrid(
                attachments: atts,
                maxWidth: 260,
                isUploading: message.id.hasPrefix("local-"),
                onTap: { url in onAttachmentTap?(url) },
                matchedNamespace: imageMatchedNS,
                activePreviewURL: activeImagePreviewURL
            )
        } else if let s = message.attachment_url,
                  let url = URL(string: s) {
            legacySingleAttachment(url: url, urlString: s)
        }
    }

    /// Attachment content WITHOUT clip — used inside a bubble so the
    /// bubble's own clipShape handles corners seamlessly.
    /// 2px padding around, fills full bubble width.
    @ViewBuilder
    private var attachmentContentUnclipped: some View {
        let imgWidth = bubbleMaxWidth - 4 // 2px padding each side
        Group {
            if let atts = message.attachments, !atts.isEmpty {
                ChatAttachmentsGrid(
                    attachments: atts,
                    maxWidth: imgWidth,
                    isUploading: message.id.hasPrefix("local-"),
                    onTap: { url in onAttachmentTap?(url) },
                    matchedNamespace: imageMatchedNS,
                    activePreviewURL: activeImagePreviewURL,
                    applyClip: false
                )
            } else if let s = message.attachment_url,
                      let url = URL(string: s) {
                CachedAsyncImage(
                    url: url,
                    contentMode: .fill,
                    placeholder: .filled,
                    fitMaxWidth: nil,
                    fitMaxHeight: nil,
                    maxPixelSize: imgWidth
                )
                .frame(width: imgWidth, height: imgWidth * 0.75)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { onAttachmentTap?(s) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(2)
    }

    private var hasAttachment: Bool {
        (message.attachments != nil && !message.attachments!.isEmpty)
            || message.attachment_url != nil
    }

    @ViewBuilder
    private var textBubble: some View {
        let parsed = ChatMessageText.parseForwarded(message.content)
        let detectedURL = ChatMessageText.firstURL(in: parsed.body)
        let hasLink = detectedURL != nil && !ComposerLinkPreview.suppressedURLs.contains(detectedURL!.absoluteString)
        let showInlineReply = (message.reply != nil) && !hideReplyPreview
        let hasText = !message.content.isEmpty
        let isShortText = hasText && parsed.body.count <= 20 && !parsed.body.contains("\n")
        let hasReactions = message.reactions?.isEmpty == false
        let showSenderName = showHeader && !isMe && isGroup
        let bubble = VStack(alignment: .leading, spacing: 0) {
            // Forwarded-from header sits at the top of the bubble so the
            // attached image / shared card / body all render below it,
            // matching Telegram's forward layout. The bubble overlay border
            // (further down) already keys off `parsed.forwardedFrom != nil`,
            // so no other layout change is needed.
            if let from = parsed.forwardedFrom {
                forwardedHeader(from: from)
            }
            // Attachment inside bubble (when there's also text)
            if hasAttachment {
                attachmentContentUnclipped
            }
            if showSenderName {
                Text(message.sender)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(message.sender.senderColor)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 0)
            }
            if showInlineReply, let reply = message.reply {
                inlineReplyQuote(for: reply)
                    .padding(.horizontal, 6)
                    .padding(.top, parsed.forwardedFrom == nil ? 6 : 2)
                    .padding(.bottom, hasText ? 2 : 6)
            }
            if hasText {
                if isShortText {
                    // Short message: text + pin + timestamp inline same row
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(ChatMessageText.attributed(parsed.body, isMe: isMe))
                            .tint(isMe ? .white : Color("AccentColor"))
                            #if targetEnvironment(macCatalyst)
                            .font(.scaledSystem(size: 17))
                            #endif
                            .textSelection(.enabled)
                        timestampMeta
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    // Long message: text with reserved bottom space for overlay timestamp
                    Text(ChatMessageText.attributed(parsed.body, isMe: isMe))
                        .tint(isMe ? .white : Color("AccentColor"))
                    #if targetEnvironment(macCatalyst)
                        .font(.scaledSystem(size: 17))
                    #endif
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, hasLink ? 12 : 8)
                        .padding(.bottom, hasLink ? 0 : (hasReactions ? 4 : 24))
                }
            }
            if let linkURL = ChatMessageText.firstURL(in: parsed.body),
               !ComposerLinkPreview.suppressedURLs.contains(linkURL.absoluteString) {
                LinkPreviewCard(url: linkURL, isMe: isMe)
                    .padding(.horizontal, 12)
                    .padding(.bottom, hasReactions ? 8 : 40)
            }
            // Reactions inside bubble
            if let reactions = message.reactions, !reactions.isEmpty {
                ChatReactionsRow(
                    reactions: reactions,
                    reactionRows: message.reactionRows ?? [],
                    myLogin: myLogin,
                    myReactionEmojis: myReactionEmojis,
                    isOutgoing: isMe,
                    onToggleReact: { emoji in onToggleReact?(emoji) },
                    onLongPress: { onMoreReactions?() },
                    onTap: { onReactionsTap?() }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 80, maxWidth: hasAttachment ? bubbleMaxWidth : nil, alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            // Only show overlay timestamp for long messages —
            // short messages have it inline in the HStack.
            if !isShortText {
                timestampMeta
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(isMe ? theme.bubbleOutgoing : theme.bubbleIncoming)
        .clipShape(bubbleClipShape)
        .foregroundStyle(isMe ? theme.bubbleOutgoingText : theme.bubbleIncomingText)
        .overlay(
            bubbleClipShape
                .strokeBorder(
                    parsed.forwardedFrom != nil
                        ? (isMe ? Color.white.opacity(0.3) : Color.secondary.opacity(0.3))
                        : Color.clear,
                    lineWidth: 1
                )
        )
        .overlay(alignment: isMe ? .bottomTrailing : .bottomLeading) {
            if showTail && theme.useBubbleTails {
                BubbleTailOverlay(
                    isOutgoing: isMe,
                    color: isMe ? theme.bubbleOutgoing : theme.bubbleIncoming
                )
                .offset(x: isMe ? 5 : -5, y: 2)
            }
        }
        #if targetEnvironment(macCatalyst)
        BubbleHugLayout(maxWidth: bubbleMaxWidth) {
            bubble
        }
        #else
        bubble
            .frame(maxWidth: bubbleMaxWidth, alignment: isMe ? .trailing : .leading)
        #endif
    }

    // MARK: Bubble clip shape

    /// When `showTail` is true, the bottom corner on the tail side uses
    /// a tighter 4pt radius so the decorative tail connects flush.
    /// Uses `UnevenRoundedRectangle` (iOS 16.4+).
    private var bubbleClipShape: UnevenRoundedRectangle {
        if showTail {
            return UnevenRoundedRectangle(
                topLeadingRadius: 20,
                bottomLeadingRadius: isMe ? 20 : 4,
                bottomTrailingRadius: isMe ? 4 : 20,
                topTrailingRadius: 20
            )
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 20,
            topTrailingRadius: 20
        )
    }

    // MARK: Bubble max-width (responsive)

    private var bubbleMaxWidth: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 560
        #else
        let screenWidth = UIScreen.main.bounds.width
        if UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory {
            return screenWidth * 0.85
        }
        return min(screenWidth * 0.75, 304)
        #endif
    }

    // MARK: Lifecycle

    private func onFirstAppear() {
        if Self.seenIds.contains(message.id) {
            appeared = true
        } else {
            Self.seenIds.insert(message.id)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                appeared = true
            }
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Clamps the text-bubble width on Catalyst so long lines stay
/// readable while letting short bubbles hug their content.
///
/// SwiftUI's `.frame(maxWidth:)` is unreliable for this use case:
/// in the UITableViewCell + UIHostingConfiguration context the
/// cell proposes the full table width, and frame modifiers —
/// especially with an `alignment:` argument — end up filling the
/// proposed width instead of hugging. Using a custom `Layout`
/// gives us direct control: we propose `maxWidth` to the subview
/// (so long text wraps at the cap) and then report the subview's
/// measured size (so short text hugs).
private struct BubbleHugLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let childProposal = ProposedViewSize(width: maxWidth, height: proposal.height)
        let measured = subview.sizeThatFits(childProposal)
        return CGSize(width: min(measured.width, maxWidth), height: measured.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
#endif
