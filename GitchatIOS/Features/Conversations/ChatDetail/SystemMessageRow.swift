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

    private static let nonLoginWords: Set<String> = [
        "added", "joined", "left", "pinned", "unpinned", "invited",
        "removed", "kicked", "created", "renamed", "changed", "the",
        "group", "message", "name", "was", "and", "to", "a", "an",
        "from", "this", "chat", "conversation",
    ]

    /// Build an attributed string where every token that looks like a
    /// GitHub login (and isn't a common English verb/article used in
    /// system messages) is bold and links to its profile.
    private var attributed: AttributedString {
        let body = message.content.isEmpty ? prettyType : message.content
        var attr = AttributedString(body)

        let pattern = "\\b[A-Za-z0-9][A-Za-z0-9-]{1,38}\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attr }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let token = ns.substring(with: m.range)
            if Self.nonLoginWords.contains(token.lowercased()) { continue }
            if let aRange = attr.range(of: token) {
                attr[aRange].font = .caption.bold()
                attr[aRange].foregroundColor = .secondary
                attr[aRange].link = URL(string: "gitchat://user/\(token)")
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                if isPinEvent { onTap?() }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
