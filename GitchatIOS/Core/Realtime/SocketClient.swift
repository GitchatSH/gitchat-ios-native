import Foundation
import SocketIO

extension NSNotification.Name {
    /// Posted on the main actor whenever the server emits
    /// `conversation:updated`. Non-list screens (e.g. the open chat detail)
    /// use it to re-read per-conversation state such as `is_muted`.
    static let gitchatConversationUpdated = NSNotification.Name("gitchat.conversationUpdated")
}

@MainActor
final class SocketClient: ObservableObject {
    static let shared = SocketClient()

    @Published private(set) var connected = false

    /// ID of the conversation currently visible in a ChatDetailView.
    /// Used to suppress in-app toast banners for the same conversation.
    @Published var currentConversationId: String?

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var subscribedConversations = Set<String>()
    /// Login of the currently authenticated user. Stored so the reconnect
    /// handler can re-emit `subscribe:user` and rebuild the backend's
    /// socket→login mapping. Cleared on `disconnect()`.
    private var subscribedUserLogin: String?

    // Event callbacks
    var onMessageSent: ((Message) -> Void)?
    var globalOnMessageSent: ((Message) -> Void)?
    var onConversationUpdated: (() -> Void)?
    var onPresenceUpdated: ((String, Bool) -> Void)?
    var onReactionUpdated: ((String) -> Void)?
    var onNotificationNew: (() -> Void)?
    var onTyping: ((String, String, Bool) -> Void)? // conversationId, login, isTyping
    var onConversationRead: ((String, String, String?) -> Void)? // conversationId, login, readAt
    var onMessagePinned: ((String, String) -> Void)? // conversationId, messageId
    var onMessageUnpinned: ((String, String) -> Void)? // conversationId, messageId

    private init() {}

    func connect() {
        guard socket == nil else { return }
        let manager = SocketManager(
            socketURL: Config.wsURL,
            config: [
                .log(false),
                .compress,
                .reconnects(true),
                .reconnectAttempts(-1),
                .extraHeaders([
                    "User-Agent": Config.userAgent
                ])
            ]
        )
        let socket = manager.defaultSocket
        self.manager = manager
        self.socket = socket

        socket.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                self?.connected = true
                // Re-emit subscribe:user so the backend rebuilds the
                // socket→login mapping after a disconnect. Without this
                // the user's own presence never goes online again.
                if let login = self?.subscribedUserLogin {
                    self?.socket?.emit("subscribe:user", ["login": login])
                }
                // Re-subscribe on reconnect
                if let subs = self?.subscribedConversations {
                    for id in subs { self?.subscribe(conversation: id) }
                }
                // Re-emit watch:presence for every user we previously
                // subscribed to so the WS server resumes streaming
                // their online/offline status after a disconnect.
                PresenceStore.shared.resubscribeAll()
            }
        }
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in self?.connected = false }
        }

        socket.on("message:sent") { [weak self] data, _ in
            guard let dict = (data.first as? [String: Any])?["data"] ?? data.first,
                  let json = try? JSONSerialization.data(withJSONObject: dict),
                  let msg = try? JSONDecoder().decode(Message.self, from: json) else { return }
            Task { @MainActor in
                self?.globalOnMessageSent?(msg)
                self?.onMessageSent?(msg)
            }
        }
        socket.on("conversation:updated") { [weak self] _, _ in
            Task { @MainActor in
                self?.onConversationUpdated?()
                NotificationCenter.default.post(name: .gitchatConversationUpdated, object: nil)
            }
        }
        let presenceHandler: NormalCallback = { [weak self] data, _ in
            // Backend shape: { event_name, data: { login, status: "online" | "offline", lastSeenAt? } }
            // Same payload is emitted on both `presence:updated` (transition) and
            // `presence:snapshot` (one-shot reply to watch:presence / subscribe:user).
            guard let dict = data.first as? [String: Any],
                  let inner = dict["data"] as? [String: Any],
                  let login = inner["login"] as? String,
                  let status = inner["status"] as? String else { return }
            let online = (status == "online")
            Task { @MainActor in self?.onPresenceUpdated?(login, online) }
        }
        socket.on("presence:updated", callback: presenceHandler)
        socket.on("presence:snapshot", callback: presenceHandler)
        socket.on("reaction:updated") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let id = dict["messageId"] as? String else { return }
            Task { @MainActor in self?.onReactionUpdated?(id) }
        }
        socket.on("notification:new") { [weak self] _, _ in
            Task { @MainActor in self?.onNotificationNew?() }
        }
        socket.on("typing:start") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let convId = dict["conversationId"] as? String,
                  let login = dict["login"] as? String else { return }
            Task { @MainActor in self?.onTyping?(convId, login, true) }
        }
        socket.on("typing:stop") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let convId = dict["conversationId"] as? String,
                  let login = dict["login"] as? String else { return }
            Task { @MainActor in self?.onTyping?(convId, login, false) }
        }
        socket.on("conversation:read") { [weak self] data, _ in
            guard let dict = (data.first as? [String: Any])?["data"] as? [String: Any] ?? (data.first as? [String: Any]),
                  let convId = dict["conversationId"] as? String,
                  let login = dict["login"] as? String else { return }
            let readAt = dict["readAt"] as? String
            Task { @MainActor in self?.onConversationRead?(convId, login, readAt) }
        }
        socket.on("message:pinned") { [weak self] data, _ in
            guard let dict = (data.first as? [String: Any])?["data"] as? [String: Any] ?? (data.first as? [String: Any]),
                  let convId = dict["conversationId"] as? String,
                  let msgId = dict["messageId"] as? String else { return }
            Task { @MainActor in self?.onMessagePinned?(convId, msgId) }
        }
        socket.on("message:unpinned") { [weak self] data, _ in
            guard let dict = (data.first as? [String: Any])?["data"] as? [String: Any] ?? (data.first as? [String: Any]),
                  let convId = dict["conversationId"] as? String,
                  let msgId = dict["messageId"] as? String else { return }
            Task { @MainActor in self?.onMessageUnpinned?(convId, msgId) }
        }

        socket.connect()
    }

    func disconnect() {
        socket?.disconnect()
        socket = nil
        manager = nil
        connected = false
        subscribedConversations.removeAll()
        subscribedUserLogin = nil
    }

    func subscribe(conversation id: String) {
        subscribedConversations.insert(id)
        socket?.emit("subscribe:conversation", ["conversationId": id])
    }

    func unsubscribe(conversation id: String) {
        subscribedConversations.remove(id)
        socket?.emit("unsubscribe:conversation", ["conversationId": id])
    }

    func watchPresence(login: String) {
        socket?.emit("watch:presence", ["login": login])
    }

    func subscribeUser(login: String) {
        subscribedUserLogin = login
        socket?.emit("subscribe:user", ["login": login])
    }

    /// Emit a WS-level presence heartbeat. Backend's handler runs the
    /// `refreshHeartbeat` Lua script to extend the user's Redis TTL and
    /// update the heartbeat ZSET score. This is the authoritative keepalive
    /// — the legacy `PATCH /presence` endpoint was removed on 2026-04-15.
    func emitPresenceHeartbeat() {
        socket?.emit("presence:heartbeat")
    }

    func emitTyping(conversationId: String, isTyping: Bool) {
        socket?.emit(isTyping ? "typing:start" : "typing:stop", ["conversationId": conversationId])
    }
}
