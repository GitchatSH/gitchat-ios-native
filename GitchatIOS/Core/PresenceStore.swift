import Foundation
import Combine

/// Tracks which GitHub logins are currently online. Drives the small
/// green dot overlaid on avatars throughout the app.
///
/// Backend contract (post 2026-04-15 presence redesign — matches the
/// webapp `use-presence` hook and the VS Code extension realtime client):
/// - `GET /presence?logins=a,b,c` → `{ data: { login: { status, lastSeenAt } } }`
/// - WS emit `subscribe:user` once on connect/reconnect
/// - WS emit `presence:heartbeat` every 30s (TTL 90s on backend)
/// - WS emit `watch:presence` per login we care about
/// - WS `presence:updated` → transition { login, status, lastSeenAt? }
/// - WS `presence:snapshot` → one-shot reply to watch:presence with the
///   current state (same payload shape as `presence:updated`)
///
/// We keep a `Set<String>` of known-online logins in memory. The
/// conversations list / chat detail / profile views call `ensure(_:)`
/// with the logins they care about; the store emits a `watch:presence`
/// on the socket so the backend streams updates and also fetches the
/// current status via REST so freshly-loaded avatars can decide
/// whether to show a dot immediately.
@MainActor
final class PresenceStore: ObservableObject {
    static let shared = PresenceStore()

    @Published private(set) var onlineLogins: Set<String> = []
    @Published private(set) var lastSeen: [String: Date] = [:]

    /// Logins we've already asked the server about (so `ensure(_:)`
    /// doesn't spam the REST endpoint as the user scrolls).
    private var watched: Set<String> = []

    private init() {}

    func start() {
        // Live updates from the socket — handles both `presence:updated`
        // (transitions) and `presence:snapshot` (initial state reply to
        // `watch:presence`/`subscribe:user`). The heartbeat emit itself
        // is driven by RootView.startHeartbeat() so we don't double up
        // on timers here.
        SocketClient.shared.onPresenceUpdated = { [weak self] login, online in
            guard let self else { return }
            if online {
                self.onlineLogins.insert(login)
            } else {
                if self.onlineLogins.remove(login) != nil {
                    self.lastSeen[login] = Date()
                }
            }
        }
    }

    /// Emit a WS heartbeat immediately — used on app foreground so the
    /// user's Redis presence TTL is refreshed the moment they come back
    /// instead of waiting up to 30s for the scheduled tick.
    func heartbeatNow() {
        SocketClient.shared.emitPresenceHeartbeat()
    }

    func isOnline(_ login: String?) -> Bool {
        guard let login, !login.isEmpty else { return false }
        return onlineLogins.contains(login)
    }

    /// Called by views that render avatars. Subscribes to `watch:presence`
    /// the first time we see a login, AND re-fetches the REST presence
    /// snapshot every call so a stale cached state can recover when the
    /// user actually comes online.
    func ensure(_ logins: [String]) {
        let cleaned = logins.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        for login in cleaned where !watched.contains(login) {
            watched.insert(login)
            SocketClient.shared.watchPresence(login: login)
        }
        // REST refresh — backend is authoritative for online/offline;
        // we just mirror the `status` field and remember `lastSeenAt`
        // for rendering "Seen Xm ago" on offline avatars.
        Task { [weak self] in
            guard let self else { return }
            if let map = try? await APIClient.shared.getPresence(logins: cleaned) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fallback = ISO8601DateFormatter()
                fallback.formatOptions = [.withInternetDateTime]
                for (login, entry) in map {
                    if entry.status == "online" {
                        self.onlineLogins.insert(login)
                    } else {
                        self.onlineLogins.remove(login)
                    }
                    if let iso = entry.lastSeenAt,
                       let date = formatter.date(from: iso) ?? fallback.date(from: iso) {
                        self.lastSeen[login] = date
                    }
                }
            }
        }
    }

    /// Force a re-subscribe to all known watched logins. Call after
    /// the socket reconnects so the WS server starts streaming
    /// presence updates for them again.
    func resubscribeAll() {
        for login in watched {
            SocketClient.shared.watchPresence(login: login)
        }
    }

}
