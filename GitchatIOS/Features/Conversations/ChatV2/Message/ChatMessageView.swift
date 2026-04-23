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

    // MARK: Local state

    @State private var showTime = false
    @State private var appeared = false

    /// Session-wide set of message ids that have already materialized
    /// on screen — so the fade-in animation only fires the *first*
    /// time a bubble appears, not on every scroll recycle. Shared
    /// with the legacy `MessageBubble` type (both live in the same
    /// module and `ChatViewModel.load` marks seen via that symbol)
    /// so the V1 → V2 transition can swap the rendering class
    /// without losing the "already seen this session" state.
    static var seenIds: Set<String> {
        get { MessageBubble.seenIds }
        set { MessageBubble.seenIds = newValue }
    }

    static func markSeen(_ ids: [String]) {
        MessageBubble.markSeen(ids)
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
        .opacity(MessageBubble.seenIds.contains(message.id) || appeared ? 1 : 0)
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
            if let reply = message.reply {
                ChatReplyPreview(reply: reply, isMe: isMe) { onReplyTap?() }
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

            // Text body.
            if !message.content.isEmpty {
                textBubble
            }
        }
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
            Text(ChatMessageText.attributed(parsed.body, isMe: isMe))
                .tint(isMe ? .white : theme.replyAccent)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, parsed.forwardedFrom == nil ? 8 : 6)
                .padding(.bottom, parsed.forwardedFrom == nil ? 0 : 2)
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
        if MessageBubble.seenIds.contains(message.id) {
            appeared = true
        } else {
            MessageBubble.seenIds.insert(message.id)
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
