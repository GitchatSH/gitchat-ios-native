import Foundation

/// Clusters consecutive same-sender incoming messages within a day
/// section so the UITableView can render them as a single grouped cell
/// with a shared avatar column.
enum ChatSenderGrouping {
    struct MessageGroup {
        let id: String           // "__group__|" + first message ID
        let messageIDs: [String]
        let sender: String
        let senderAvatar: String?
    }

    enum Item {
        case single(String)
        case group(MessageGroup)

        var snapshotID: String {
            switch self {
            case .single(let id): return id
            case .group(let g): return g.id
            }
        }
    }

    static let groupPrefix = "__group__|"

    /// Groups consecutive same-sender incoming user messages.
    /// Only active for group conversations (`isGroup == true`).
    /// Returns items in the same order as the input `messageIDs`.
    static func group(
        messageIDs: [String],
        lookup: (String) -> Message?,
        isMe: (Message) -> Bool,
        isGroup: Bool
    ) -> [Item] {
        guard isGroup else { return messageIDs.map { .single($0) } }

        var result: [Item] = []
        var currentRun: [String] = []
        var currentSender: String?
        var currentAvatar: String?

        for id in messageIDs {
            guard let msg = lookup(id) else {
                flushRun(&result, &currentRun, &currentSender, &currentAvatar)
                result.append(.single(id))
                continue
            }

            // Only group incoming user messages
            let isUserMsg = msg.type == nil || msg.type == "user"
            if !isUserMsg || isMe(msg) {
                flushRun(&result, &currentRun, &currentSender, &currentAvatar)
                result.append(.single(id))
                continue
            }

            if msg.sender == currentSender {
                currentRun.append(id)
            } else {
                flushRun(&result, &currentRun, &currentSender, &currentAvatar)
                currentSender = msg.sender
                currentAvatar = msg.sender_avatar
                currentRun = [id]
            }
        }
        flushRun(&result, &currentRun, &currentSender, &currentAvatar)
        return result
    }

    private static func flushRun(
        _ result: inout [Item],
        _ run: inout [String],
        _ sender: inout String?,
        _ avatar: inout String?
    ) {
        guard !run.isEmpty else { return }
        if run.count == 1 {
            result.append(.single(run[0]))
        } else {
            result.append(.group(MessageGroup(
                id: "\(groupPrefix)\(run[0])",
                messageIDs: run,
                sender: sender ?? "unknown",
                senderAvatar: avatar
            )))
        }
        run = []
        sender = nil
        avatar = nil
    }
}
