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

    /// Build an attributed string where the leading user login (which
    /// backend always emits bare, e.g. "alice pinned a message") is bold
    /// and clickable via the gitchat://user/ scheme.
    private var attributed: AttributedString {
        let body = message.content.isEmpty ? prettyType : message.content
        var attr = AttributedString(body)

        if let space = body.firstIndex(of: " ") {
            let login = String(body[..<space])
            if login.range(of: "^[A-Za-z0-9][A-Za-z0-9-]*$", options: .regularExpression) != nil,
               let aRange = attr.range(of: login) {
                attr[aRange].font = .caption.bold()
                attr[aRange].foregroundColor = .secondary
                attr[aRange].link = URL(string: "gitchat://user/\(login)")
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
