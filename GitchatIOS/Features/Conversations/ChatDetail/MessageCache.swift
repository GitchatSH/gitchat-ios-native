import Foundation

/// Shared in-memory cache of the first page of messages per conversation.
/// Populated by ConversationsViewModel.prefetch() when the chat list loads,
/// and read by ChatViewModel on init so chat detail opens with content
/// already on screen instead of waiting for a network round trip.
@MainActor
final class MessageCache {
    static let shared = MessageCache()

    struct Entry: Codable {
        let messages: [Message]
        let nextCursor: String?
        let otherReadAt: String?
        let fetchedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inflight: [String: Task<Void, Never>] = [:]

    private let diskQueue = DispatchQueue(label: "chat.git.MessageCache.disk", qos: .utility)

    private init() {}

    private nonisolated var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MessageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated func fileURL(_ conversationId: String) -> URL {
        directory.appendingPathComponent("\(conversationId).json")
    }

    func get(_ conversationId: String) -> Entry? {
        if let mem = entries[conversationId] { return mem }
        // Lazy disk load — synchronous because callers (ChatViewModel.init)
        // need it on the hot path. JSON files are small (one chat page).
        guard let data = try? Data(contentsOf: fileURL(conversationId)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        entries[conversationId] = entry
        return entry
    }

    func store(_ conversationId: String, entry: Entry) {
        entries[conversationId] = entry
        let url = fileURL(conversationId)
        diskQueue.async {
            if let data = try? JSONEncoder().encode(entry) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Kick off a background fetch for this conversation if one isn't
    /// already running. Safe to call repeatedly.
    func prefetch(conversationId: String) {
        if inflight[conversationId] != nil { return }
        let task = Task { [weak self] in
            defer { self?.inflight[conversationId] = nil }
            do {
                let resp = try await APIClient.shared.getConversationMessages(id: conversationId)
                self?.store(conversationId, entry: Entry(
                    messages: resp.messages.reversed(),
                    nextCursor: resp.nextCursor,
                    otherReadAt: resp.otherReadAt,
                    fetchedAt: Date()
                ))
            } catch {
                // Silent — chat detail will retry on its own load().
            }
        }
        inflight[conversationId] = task
    }

    /// Prefetch a list of conversations with a small concurrency limit to
    /// avoid hammering the API.
    func prefetchAll(_ ids: [String], concurrency: Int = 4) {
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var iterator = ids.makeIterator()
                var inFlight = 0
                while let id = iterator.next() {
                    if inFlight >= concurrency {
                        await group.next()
                        inFlight -= 1
                    }
                    let convId = id
                    group.addTask { @MainActor in
                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            self.prefetch(conversationId: convId)
                            // Wait for the inflight task to finish.
                            if let t = self.inflight[convId] {
                                Task { await t.value; cont.resume() }
                            } else {
                                cont.resume()
                            }
                        }
                    }
                    inFlight += 1
                }
            }
        }
    }
}
