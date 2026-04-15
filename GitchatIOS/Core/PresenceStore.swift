import Foundation
import Combine

/// Tracks which GitHub logins are currently online. Drives the small
/// green dot overlaid on avatars throughout the app.
///
/// Backend surface (see `misc` module):
/// - `GET /presence?logins=a,b,c` → `{ presence: { login: isoDate | null } }`
/// - `PATCH /presence` → heartbeat for the authenticated user
/// - WS `presence:updated` → `{ data: { login, status: "online" | "offline" } }`
///
/// We keep a `Set<String>` of known-online logins in memory. The
/// conversations list / chat detail / profile views call `ensure(_:)`
/// with the logins they care about; the store emits a `watch:presence`
/// on the socket so the backend streams updates and also fetches the
/// current `lastSeenAt` via REST so freshly-loaded avatars can decide
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
        // Live updates from the socket. The actual PATCH /presence
        // heartbeat is driven by RootView.startHeartbeat() so we don't
        // double up on timers here.
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

    /// Fire a PATCH /presence immediately — used on app foreground so
    /// the DB `last_seen_at` column is fresh the moment the user
    /// returns to the app.
    func heartbeatNow() {
        Task { try? await APIClient.shared.heartbeat() }
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
        // REST refresh — treat users seen in the last 90s as online.
        Task { [weak self] in
            guard let self else { return }
            if let map = try? await APIClient.shared.getPresence(logins: cleaned) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fallback = ISO8601DateFormatter()
                fallback.formatOptions = [.withInternetDateTime]
                let now = Date()
                for (login, iso) in map {
                    guard let iso else {
                        // Server says we have no last_seen_at on file
                        // — leave any in-memory state as-is.
                        continue
                    }
                    let date = formatter.date(from: iso) ?? fallback.date(from: iso)
                    guard let date else { continue }
                    self.lastSeen[login] = date
                    if now.timeIntervalSince(date) < 90 {
                        self.onlineLogins.insert(login)
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
