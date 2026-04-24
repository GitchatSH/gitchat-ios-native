import SwiftUI
import UIKit

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
/// - `showTime`: tap-to-toggle relative time above the bubble.
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

    // MARK: Local state

    @State private var showTime = false
    @State private var appeared = false

    /// Session-wide set of message ids that have already materialized
    /// on screen — so the fade-in animation only fires the *first*
    /// time a bubble appears, not on every scroll recycle.
    nonisolated(unsafe) static var seenIds: Set<String> = []

    static func markSeen(_ ids: [String]) {
        for id in ids { seenIds.insert(id) }
    }

    // MARK: Body

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMe {
                Spacer(minLength: 40)
            } else {
                avatarColumn
            }
            bubbleColumn
            if !isMe { Spacer(minLength: 40) }
        }
        .opacity(Self.seenIds.contains(message.id) || appeared ? 1 : 0)
        .onAppear(perform: onFirstAppear)
    }

    // MARK: Avatar column

    @ViewBuilder
    private var avatarColumn: some View {
        if showHeader {
            AvatarView(
                url: resolvedAvatar ?? message.sender_avatar,
                size: 28,
                login: message.sender
            )
            .contentShape(Circle())
            .onTapGesture { onAvatarTap?() }
            .instantTooltip("@\(message.sender)")
        } else {
            // Keep the column width stable when consecutive messages
            // from the same sender omit the avatar, so bubbles line up.
            Color.clear.frame(width: 28, height: 28)
        }
    }

    // MARK: Bubble column (header row / reply / bubble / reactions)

    @ViewBuilder
    private var bubbleColumn: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
            if showTime {
                Text(RelativeTime.format(message.created_at))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !isMe && showHeader {
                Text(message.sender)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            bubble
                .overlay(alignment: .topTrailing) { pinBadge }
                .scaleEffect(isPulsing ? 1.08 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isPulsing)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { showTime.toggle() }
                }
                .instantTooltip(ChatMessageText.fullTimestamp(message.created_at))
            if message.edited_at != nil {
                Text("edited")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .instantTooltip("Edited \(ChatMessageText.fullTimestamp(message.edited_at))")
            }
            if let reactions = message.reactions, !reactions.isEmpty {
                ChatReactionsRow(
                    reactions: reactions,
                    myLogin: myLogin,
                    myReactionEmojis: myReactionEmojis,
                    onTap: { onReactionsTap?() }
                )
            }
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

    // MARK: Pin badge

    @ViewBuilder
    private var pinBadge: some View {
        if isPinned {
            Button { onPinTap?() } label: {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(45))
                    .padding(5)
                    .background(theme.replyAccent, in: Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
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
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var textAndAttachmentBubble: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
            // Attachments — grid (iMessage-style 1/2/3/4+).
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

            // Text body. Render the bubble when there's text OR
            // when this is a reply (the inline quote lives inside
            // the bubble as part of its content, not as a separate
            // pre-bubble element).
            if !message.content.isEmpty ||
                (message.reply != nil && !hideReplyPreview) {
                textBubble
            }
        }
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
        VStack(alignment: .leading, spacing: 1) {
            if let login = reply.sender_login {
                Text("@\(login)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isMe ? Color.white : theme.replyAccent)
            }
            Text(reply.body ?? "…")
                .font(.system(size: 12))
                .foregroundStyle(isMe ? Color.white.opacity(0.85) : .secondary)
                .lineLimit(2)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isMe ? Color.white : theme.replyAccent)
                .frame(width: 3)
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isMe ? Color.white.opacity(0.18) : Color.black.opacity(0.06),
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

    @ViewBuilder
    private var textBubble: some View {
        let parsed = ChatMessageText.parseForwarded(message.content)
        let hasLink = ChatMessageText.firstURL(in: parsed.body) != nil
        let showInlineReply = (message.reply != nil) && !hideReplyPreview
        let hasText = !message.content.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            if let from = parsed.forwardedFrom {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Forwarded from @\(from)")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(isMe ? Color.white.opacity(0.85) : .secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            if showInlineReply, let reply = message.reply {
                inlineReplyQuote(for: reply)
                    .padding(.horizontal, 6)
                    .padding(.top, parsed.forwardedFrom == nil ? 6 : 2)
                    .padding(.bottom, hasText ? 2 : 6)
            }
            if hasText {
                Text(ChatMessageText.attributed(parsed.body, isMe: isMe))
                    .tint(isMe ? .white : theme.replyAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, parsed.forwardedFrom == nil && !showInlineReply ? 8 : 6)
                    .padding(.bottom, parsed.forwardedFrom == nil && !showInlineReply ? 0 : 2)
            }
            if let linkURL = ChatMessageText.firstURL(in: parsed.body) {
                LinkPreviewCard(url: linkURL, isMe: isMe)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
        }
        #if targetEnvironment(macCatalyst)
        .modifier(MacLinkBubbleWidthV2(hasLink: hasLink))
        #endif
        .background(isMe ? theme.bubbleOutgoing : theme.bubbleIncoming)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(isMe ? theme.bubbleOutgoingText : theme.bubbleIncomingText)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    parsed.forwardedFrom != nil
                        ? (isMe ? Color.white.opacity(0.3) : Color.secondary.opacity(0.3))
                        : Color.clear,
                    lineWidth: 1
                )
        )
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
/// Clamps the text-bubble width on Catalyst when a link preview is
/// present so the preview card stays readable (the bubble otherwise
/// grows to fill the available space and the card stretches).
private struct MacLinkBubbleWidthV2: ViewModifier {
    let hasLink: Bool
    func body(content: Content) -> some View {
        if hasLink {
            content.frame(maxWidth: 312, alignment: .leading)
        } else {
            content
        }
    }
}
#endif
