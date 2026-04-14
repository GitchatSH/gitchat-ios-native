import Foundation
import SocketIO

@MainActor
final class SocketClient: ObservableObject {
    static let shared = SocketClient()

    @Published private(set) var connected = false

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var subscribedConversations = Set<String>()

    // Event callbacks
    var onMessageSent: ((Message) -> Void)?
    var onConversationUpdated: (() -> Void)?
    var onPresenceUpdated: ((String, Bool) -> Void)?
    var onReactionUpdated: ((String) -> Void)?
    var onNotificationNew: (() -> Void)?

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
            Task { @MainActor in self?.onMessageSent?(msg) }
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
}
