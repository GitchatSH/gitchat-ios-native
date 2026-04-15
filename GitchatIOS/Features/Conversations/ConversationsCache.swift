import Foundation

/// Disk-backed cache of the conversation list so cold launches show the
/// previous chat list instantly, then revalidate from the network.
@MainActor
final class ConversationsCache {
    static let shared = ConversationsCache()

    private var memory: [Conversation]?
    private let diskQueue = DispatchQueue(label: "chat.git.ConversationsCache.disk", qos: .utility)

    private init() {}

    private nonisolated var fileURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("conversations.json")
    }

    func get() -> [Conversation]? {
        if let mem = memory { return mem }
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Conversation].self, from: data)
        else { return nil }
        memory = list
        return list
    }

    func store(_ conversations: [Conversation]) {
        memory = conversations
        let url = fileURL
        diskQueue.async {
            if let data = try? JSONEncoder().encode(conversations) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
