import SwiftUI

struct MessageBubble: View {
    let message: Message
    let isMe: Bool
    var myLogin: String? = nil
    var resolvedAvatar: String? = nil
    var showHeader: Bool = true
    var isPinned: Bool = false
    var onReactionsTap: (() -> Void)? = nil
    var onReplyTap: (() -> Void)? = nil
    var onAttachmentTap: ((String) -> Void)? = nil
    var onPinTap: (() -> Void)? = nil
    var onAvatarTap: (() -> Void)? = nil
    var isPulsing: Bool = false
    var bubbleContextMenu: (() -> AnyView)? = nil
    @State private var showTime = false
    @State private var appeared = false

    /// Session-wide set of message ids that have already been seen on
    /// screen — so the pop-in animation only fires the *first* time a
    /// bubble materializes, not on every scroll recycle.
    nonisolated(unsafe) static var seenIds: Set<String> = []

    static func markSeen(_ ids: [String]) {
        for id in ids { seenIds.insert(id) }
    }

    private func didReact(_ emoji: String) -> Bool {
        guard let me = myLogin else { return false }
        return (message.reactionRows ?? []).contains { $0.emoji == emoji && $0.user_login == me }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMe { Spacer(minLength: 40) } else {
                if showHeader {
                    AvatarView(
                        url: resolvedAvatar ?? message.sender_avatar,
                        size: 28,
                        login: message.sender
                    )
                    .contentShape(Circle())
                    .onTapGesture { onAvatarTap?() }
                } else {
                    Color.clear.frame(width: 28, height: 28)
                }
            }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if showTime {
                    Text(RelativeTime.format(message.created_at))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if !isMe && showHeader {
                    Text(message.sender).font(.caption2).foregroundStyle(.secondary)
                }
                if let reply = message.reply {
                    replyPreview(reply)
                        .contentShape(Rectangle())
                        .onTapGesture { onReplyTap?() }
                }
                Group {
                    if let menuBuilder = bubbleContextMenu {
                        bubbleContent.contextMenu { menuBuilder() }.tint(.primary)
                    } else {
                        bubbleContent
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isPinned {
                        Button {
                            onPinTap?()
                        } label: {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .rotationEffect(.degrees(45))
                                .padding(5)
                                .background(Color.accentColor, in: Circle())
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 10, y: -10)
                    }
                }
                .scaleEffect(isPulsing ? 1.08 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isPulsing)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { showTime.toggle() }
                }
                if message.edited_at != nil {
                    Text("edited").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if let reactions = message.reactions, !reactions.isEmpty {
                    reactionsRow(reactions)
                }
            }
            if !isMe { Spacer(minLength: 40) }
        }
        .scaleEffect(Self.seenIds.contains(message.id) || appeared ? 1 : 0.7, anchor: isMe ? .bottomTrailing : .bottomLeading)
        .opacity(Self.seenIds.contains(message.id) || appeared ? 1 : 0)
        .onAppear {
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

    private func attachmentImage(for url: URL) -> some View {
        CachedAsyncImage(url: url, contentMode: .fit, fixedHeight: 220)
    }

    /// Single-image chat attachment: caps at 260 wide / 280 tall and
    /// keeps the image's natural aspect ratio. Wide photos shrink in
    /// height; tall photos shrink in width so neither dimension
    /// dominates the bubble.
    @ViewBuilder
    private func singleAttachmentImage(for url: URL, width: Int? = nil, height: Int? = nil) -> some View {
        let maxW: CGFloat = 260
        let maxH: CGFloat = 220
        if let w = width, let h = height, w > 0, h > 0 {
            let aspect = CGFloat(w) / CGFloat(h)
            let fitted: CGSize = {
                if aspect >= 1 {
                    let fw = min(maxW, CGFloat(w))
                    return CGSize(width: fw, height: fw / aspect)
                } else {
                    let fh = min(maxH, CGFloat(h))
                    return CGSize(width: fh * aspect, height: fh)
                }
            }()
            CachedAsyncImage(url: url, contentMode: .fit)
                .frame(width: fitted.width, height: fitted.height)
        } else {
            // Dimensionless: CachedAsyncImage computes its own tight
            // frame from the loaded image's intrinsic aspect ratio.
            CachedAsyncImage(
                url: url,
                contentMode: .fit,
                fitMaxWidth: maxW,
                fitMaxHeight: maxH
            )
        }
    }

    @ViewBuilder
    private func reactionsRow(_ reactions: [MessageReaction]) -> some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.emoji) { r in
                reactionChip(r)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .animation(
            .spring(response: 0.35, dampingFraction: 0.55),
            value: reactions.map { "\($0.emoji)|\($0.count)" }
        )
        .contentShape(Rectangle())
        .onTapGesture { onReactionsTap?() }
    }

    @ViewBuilder
    private func reactionChip(_ r: MessageReaction) -> some View {
        let mine = didReact(r.emoji)
        let label = Group {
            if #available(iOS 17.0, *) {
                Text("\(r.emoji) \(r.count)")
                    .contentTransition(.numericText(value: Double(r.count)))
            } else {
                Text("\(r.emoji) \(r.count)")
            }
        }
        label
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                mine
                    ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                    : AnyShapeStyle(.ultraThinMaterial)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    mine ? Color.accentColor.opacity(0.6) : Color.clear,
                    lineWidth: 1
                )
            )
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
                    singleAttachmentImage(for: imageURL)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .onTapGesture { onAttachmentTap?(url) }
                }
                if !message.content.isEmpty {
                    let parsed = Self.parseForwarded(message.content)
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
                        Text(Self.attributed(parsed.body, isMe: isMe))
                            .tint(isMe ? .white : Color.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, parsed.forwardedFrom == nil ? 8 : 6)
                            .padding(.bottom, parsed.forwardedFrom == nil ? 0 : 2)
                        if let linkURL = Self.firstURL(in: parsed.body) {
                            LinkPreviewCard(url: linkURL, isMe: isMe)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 6)
                        }
                    }
                    #if targetEnvironment(macCatalyst)
                    .modifier(MacLinkBubbleWidth(hasLink: Self.firstURL(in: parsed.body) != nil))
                    #endif
                    .background(
                        isMe ? Color.accentColor : Color(.secondarySystemBackground)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(isMe ? .white : .primary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(
                                parsed.forwardedFrom != nil ? (isMe ? Color.white.opacity(0.3) : Color.secondary.opacity(0.3)) : Color.clear,
                                lineWidth: 1
                            )
                    )
                }
            }
        }
    }

    private static let forwardedRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^> Forwarded from @([A-Za-z0-9-]+)\\n\\n")
    }()

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static func firstURL(in text: String) -> URL? {
        guard let detector = linkDetector else { return nil }
        let ns = text as NSString
        let match = detector.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        return match?.url
    }

    private static let mentionRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "@[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})", options: [])
    }()

    private static let attributedCache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 500
        return c
    }()

    static func parseForwarded(_ raw: String) -> (forwardedFrom: String?, body: String) {
        guard let regex = forwardedRegex,
              let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: raw.utf16.count)),
              match.numberOfRanges >= 2,
              let nameRange = Range(match.range(at: 1), in: raw),
              let fullRange = Range(match.range, in: raw)
        else {
            return (nil, raw)
        }
        let login = String(raw[nameRange])
        let body = String(raw[fullRange.upperBound...])
        return (login, body)
    }

    static func attributed(_ raw: String, isMe: Bool) -> AttributedString {
        let key = "\(isMe ? 1 : 0)|\(raw)" as NSString
        if let cached = attributedCache.object(forKey: key) {
            return AttributedString(cached)
        }
        var attr = AttributedString(raw)
        if let detector = linkDetector {
            let ns = raw as NSString
            let matches = detector.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard let url = m.url,
                      let r = Range(m.range, in: raw),
                      let aRange = attr.range(of: String(raw[r])) else { continue }
                attr[aRange].link = url
                attr[aRange].font = .body.bold()
                attr[aRange].underlineStyle = .single
            }
        }
        if let regex = mentionRegex {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard let r = Range(m.range, in: raw) else { continue }
                let token = String(raw[r])
                if let aRange = attr.range(of: token) {
                    attr[aRange].font = .body.bold()
                    let login = String(token.dropFirst())
                    attr[aRange].link = URL(string: "gitchat://user/\(login)")
                }
            }
        }
        attributedCache.setObject(NSAttributedString(attr), forKey: key)
        return attr
    }

    @ViewBuilder
    private func attachmentGrid(_ atts: [MessageAttachment]) -> some View {
        if atts.count == 1, let a = atts.first, let url = URL(string: a.url) {
            singleAttachmentImage(for: url, width: a.width, height: a.height)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
                .onTapGesture { onAttachmentTap?(a.url) }
                .contextMenu { imageActions(for: url) }
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(120), spacing: 4), count: 2),
                spacing: 4
            ) {
                ForEach(atts) { a in
                    if let url = URL(string: a.url) {
                        attachmentImage(for: url)
                            .frame(width: 120, height: 120)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                            .onTapGesture { onAttachmentTap?(a.url) }
                            .contextMenu { imageActions(for: url) }
                    }
                }
            }
            .frame(maxWidth: 248)
        }
    }

    @ViewBuilder
    private func imageActions(for url: URL) -> some View {
        ShareLink(item: url) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button {
            Task { await ImageDownloader.saveToPhotos(url: url) }
        } label: {
            Label("Save to Photos", systemImage: "arrow.down.to.line")
        }
        // Re-attach the parent bubble's actions so an image long-press
        // still gives the user the normal message options (Reply, Pin,
        // Forward, Delete, etc.) on top of Share / Save.
        if let menu = bubbleContextMenu {
            Divider()
            menu()
        }
    }
}

#if targetEnvironment(macCatalyst)
private struct MacLinkBubbleWidth: ViewModifier {
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

