import Foundation
import SocketIO

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

    // Event callbacks
    var onMessageSent: ((Message) -> Void)?
    var globalOnMessageSent: ((Message) -> Void)?
    var onConversationUpdated: (() -> Void)?
    var onPresenceUpdated: ((String, Bool) -> Void)?
    var onReactionUpdated: ((String) -> Void)?
    var onNotificationNew: (() -> Void)?
    var onTyping: ((String, String, Bool) -> Void)? // conversationId, login, isTyping
    var onConversationRead: ((String, String) -> Void)? // conversationId, login

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
                // Re-subscribe on reconnect
                if let subs = self?.subscribedConversations {
                    for id in subs { self?.subscribe(conversation: id) }
                }
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
            Task { @MainActor in self?.onConversationUpdated?() }
        }
        socket.on("presence:updated") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let user = dict["user"] as? String,
                  let online = dict["online"] as? Bool else { return }
            Task { @MainActor in self?.onPresenceUpdated?(user, online) }
        }
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
            Task { @MainActor in self?.onConversationRead?(convId, login) }
        }

        socket.connect()
    }

    func disconnect() {
        socket?.disconnect()
        socket = nil
        manager = nil
        connected = false
        subscribedConversations.removeAll()
    }

    func subscribe(conversation id: String) {
        subscribedConversations.insert(id)
        socket?.emit("subscribe:conversation", ["conversationId": id])
    }

    func unsubscribe(conversation id: String) {
        subscribedConversations.remove(id)
        socket?.emit("unsubscribe:conversation", ["conversationId": id])
    }

    func subscribeUser(login: String) {
        socket?.emit("subscribe:user", ["login": login])
    }

    func emitTyping(conversationId: String, isTyping: Bool) {
        socket?.emit(isTyping ? "typing:start" : "typing:stop", ["conversationId": conversationId])
    }
}
