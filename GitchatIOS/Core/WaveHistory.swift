import SwiftUI

/// Session-local record of who this user has already waved at in the
/// current app session. Mirrors the extension's `wavedSetThisSession` —
/// **not persisted**, resets on every launch. BE enforces the real
/// ratelimit/dedup; this just keeps the UI honest so the button stops
/// rendering "Wave" after a successful tap.
@MainActor
final class WaveHistory: ObservableObject {
    static let shared = WaveHistory()

    @Published private(set) var waved: Set<String> = []   // lowercased logins
    @Published private(set) var pending: Set<String> = []

    private init() {}

    func alreadyWaved(_ login: String) -> Bool {
        waved.contains(login.lowercased())
    }

    func isPending(_ login: String) -> Bool {
        pending.contains(login.lowercased())
    }

    func markPending(_ login: String) {
        pending.insert(login.lowercased())
    }

    func markWaved(_ login: String) {
        let l = login.lowercased()
        pending.remove(l)
        waved.insert(l)
    }

    func markFailed(_ login: String) {
        pending.remove(login.lowercased())
    }
}
