import SwiftUI

struct MessageBubble: View {
    let message: Message
    let isMe: Bool
    var resolvedAvatar: String? = nil
    var showHeader: Bool = true
    var isPinned: Bool = false
    var onReactionsTap: (() -> Void)? = nil
    var onReplyTap: (() -> Void)? = nil
    var onAttachmentTap: ((String) -> Void)? = nil
    var isPulsing: Bool = false
    var bubbleContextMenu: (() -> AnyView)? = nil
    @State private var showTime = false

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
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(45))
                            .padding(5)
                            .background(Color.accentColor, in: Circle())
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                            .offset(x: 10, y: -10)
                    }
                }
                .scaleEffect(isPulsing ? 1.05 : 1)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { showTime.toggle() }
                }
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

    private func attachmentImage(for url: URL) -> some View {
        CachedAsyncImage(url: url, contentMode: .fit, fixedHeight: 220)
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
                        .onTapGesture { onAttachmentTap?(url) }
                }
                if !message.content.isEmpty {
                    let parsed = Self.parseForwarded(message.content)
                    VStack(alignment: isMe ? .trailing : .leading, spacing: 0) {
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
                            .padding(.horizontal, 12)
                            .padding(.vertical, parsed.forwardedFrom == nil ? 8 : 6)
                            .padding(.bottom, parsed.forwardedFrom == nil ? 0 : 2)
                    }
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

    static func parseForwarded(_ raw: String) -> (forwardedFrom: String?, body: String) {
        let pattern = "^> Forwarded from @([A-Za-z0-9-]+)\\n\\n"
        guard let regex = try? NSRegularExpression(pattern: pattern),
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
        var attr = AttributedString(raw)
        // URLs via NSDataDetector
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
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
        // @mentions
        if let regex = try? NSRegularExpression(pattern: "@[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})", options: []) {
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
        return attr
    }

    @ViewBuilder
    private func attachmentGrid(_ atts: [MessageAttachment]) -> some View {
        if atts.count == 1, let a = atts.first, let url = URL(string: a.url) {
            attachmentImage(for: url)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
                .onTapGesture { onAttachmentTap?(a.url) }
                .contextMenu { imageActions(for: url) }
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 2),
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
    }
}
