import SwiftUI

struct SystemMessageRow: View {
    let message: Message
    var onTap: (() -> Void)? = nil

    private var prettyType: String {
        switch message.type {
        case "pin": return "\(message.sender) pinned a message"
        case "unpin": return "\(message.sender) unpinned a message"
        case "join": return "\(message.sender) joined"
        case "leave": return "\(message.sender) left"
        case "invite": return "\(message.sender) was invited"
        case "group_created": return "\(message.sender) created the group"
        case "rename": return "\(message.sender) renamed the group"
        default: return message.type ?? ""
        }
    }

    /// Build an attributed string. Linkify only the known
    /// `message.sender` login (outside of any quoted segments) and any
    /// explicit `@login` mention. Previously this scanned every
    /// GitHub-login-shaped token and bold-linked matches, which turned
    /// plain English inside user-provided strings (e.g. a group name
    /// like "hot fix") into false-positive profile links.
    private var attributed: AttributedString {
        let body = message.content.isEmpty ? prettyType : message.content
        var attr = AttributedString(body)

        // Ranges of `"..."` segments — content inside user-provided
        // quotes stays plain text so group names aren't linkified.
        var quotedRanges: [Range<String.Index>] = []
        var searchStart = body.startIndex
        while let open = body.range(of: "\"", range: searchStart..<body.endIndex),
              let close = body.range(of: "\"", range: open.upperBound..<body.endIndex) {
            quotedRanges.append(open.lowerBound..<close.upperBound)
            searchStart = close.upperBound
        }

        func linkify(token: String, login: String) {
            guard !token.isEmpty else { return }
            var cursor = body.startIndex
            while let r = body.range(of: token, range: cursor..<body.endIndex) {
                cursor = r.upperBound
                if quotedRanges.contains(where: { $0.overlaps(r) }) { continue }
                if let aRange = Range(r, in: attr) {
                    attr[aRange].font = .caption.bold()
                    attr[aRange].foregroundColor = .secondary
                    attr[aRange].link = URL(string: "gitchat://user/\(login)")
                }
            }
        }

        linkify(token: message.sender, login: message.sender)

        // Explicit @mentions inside the body.
        let mentionPattern = "@([A-Za-z0-9][A-Za-z0-9-]{0,38})"
        if let regex = try? NSRegularExpression(pattern: mentionPattern) {
            let ns = body as NSString
            let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges >= 2 {
                let login = ns.substring(with: m.range(at: 1))
                linkify(token: "@\(login)", login: login)
            }
        }

        return attr
    }

    private var isPinEvent: Bool {
        message.type == "pin" || message.type == "unpin" ||
        message.content.localizedCaseInsensitiveContains("pinned a message")
    }
    private var isRenameEvent: Bool {
        message.type == "rename" ||
        message.content.localizedCaseInsensitiveContains("renamed")
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if isPinEvent {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(45))
                } else if isRenameEvent {
                    Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text(attributed)
                    .font(.caption2)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isPinEvent { onTap?() }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}
