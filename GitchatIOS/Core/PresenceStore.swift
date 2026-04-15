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

    /// Logins we've already asked the server about (so `ensure(_:)`
    /// doesn't spam the REST endpoint as the user scrolls).
    private var watched: Set<String> = []
    private var heartbeatTask: Task<Void, Never>?

    private init() {}

    func start() {
        // Live updates from the socket.
        SocketClient.shared.onPresenceUpdated = { [weak self] login, online in
            guard let self else { return }
            if online { self.onlineLogins.insert(login) }
            else { self.onlineLogins.remove(login) }
        }
        // Kick off the heartbeat so the server considers us online.
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await APIClient.shared.heartbeat()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { return }
                await self?.tick()
            }
        }
    }

    private func tick() {}

    /// Call the server heartbeat once immediately (on foreground etc.).
    func heartbeatNow() {
        Task { try? await APIClient.shared.heartbeat() }
    }

    func isOnline(_ login: String?) -> Bool {
        guard let login, !login.isEmpty else { return false }
        return onlineLogins.contains(login)
    }

    /// Called by views that render avatars. Ensures the given logins
    /// are being watched on the socket and seeds initial state via REST.
    func ensure(_ logins: [String]) {
        let new = logins.filter { !watched.contains($0) && !$0.isEmpty }
        guard !new.isEmpty else { return }
        for login in new {
            watched.insert(login)
            SocketClient.shared.watchPresence(login: login)
        }
        // REST fallback — treat users seen in the last 90s as online.
        Task { [weak self] in
            guard let self else { return }
            if let map = try? await APIClient.shared.getPresence(logins: new) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fallback = ISO8601DateFormatter()
                fallback.formatOptions = [.withInternetDateTime]
                let now = Date()
                for (login, iso) in map {
                    guard let iso else { continue }
                    let date = formatter.date(from: iso) ?? fallback.date(from: iso)
                    if let date, now.timeIntervalSince(date) < 90 {
                        self.onlineLogins.insert(login)
                    }
                }
            }
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
}
