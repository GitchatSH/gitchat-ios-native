import Foundation
import OneSignalFramework

/// Observes OneSignal push-subscription changes and mirrors them to
/// the backend so BE can target pushes by subscription id directly
/// (see `POST /user/push-subscriptions`). This is the reliability
/// fix for the long-standing iOS bug where push notifications
/// silently stopped working after a TestFlight / App Store update —
/// the old path depended on tag filters that didn't survive update
/// reliably.
///
/// What we sync:
///   - On every push-subscription change (new id, new token, opt-in
///     toggle), if the user is signed in, POST the current
///     subscription id to BE.
///   - On sign out, DELETE the current subscription id from BE so
///     pushes stop hitting the device.
///   - On app foreground (scene active), re-POST even if nothing
///     changed — updates `last_seen_at` on the BE row and papers
///     over a dropped initial POST if the first run happened before
///     auth was ready.
///
/// Resilience:
///   - Every network call is fire-and-forget with a small retry, so
///     a transient failure doesn't leave the user permanently
///     mismatched. The next observer tick or scene-active tick will
///     retry.
///   - The last successfully-registered subscription id is cached in
///     UserDefaults. If OneSignal hands us a new id and the old one
///     is still on file, we DELETE the old before registering the
///     new — prevents BE row leaks when iOS rotates the APNs token.
@MainActor
final class PushSubscriptionSync: NSObject, OSPushSubscriptionObserver {
    static let shared = PushSubscriptionSync()

    private let lastRegisteredIdKey = "push.lastRegisteredSubscriptionId"
    private var observing = false

    private override init() {
        super.init()
    }

    /// Install the observer on OneSignal. Safe to call multiple times —
    /// guarded by an internal flag. Paired with `PushManager.bootstrap`
    /// so the SDK is already initialized when the observer attaches.
    func start() {
        guard !observing else { return }
        OneSignal.User.pushSubscription.addObserver(self)
        observing = true
        // Kick an initial sync in case the subscription is already
        // live at bootstrap time (common on warm launches after an
        // update — the observer fire happens only on *change*, which
        // might not happen this session).
        Task { await syncCurrent() }
    }

    /// Called from `GitchatApp` on scene-active transitions. Also
    /// called after a successful sign-in. Idempotent.
    func syncCurrent() async {
        guard AuthStore.shared.isAuthenticated else { return }
        guard let currentId = OneSignal.User.pushSubscription.id,
              !currentId.isEmpty else {
            // No subscription yet — OneSignal hasn't received an
            // APNs token. The observer will fire later with the id.
            return
        }
        await register(currentId)
    }

    /// Called on sign out. Best-effort unregister of whatever
    /// subscription id we last saw for this user, so BE doesn't keep
    /// hitting this device for a user who logged out.
    func onSignOut() async {
        if let lastId = UserDefaults.standard.string(forKey: lastRegisteredIdKey),
           !lastId.isEmpty {
            _ = try? await APIClient.shared.unregisterPushSubscription(subscriptionId: lastId)
        }
        UserDefaults.standard.removeObject(forKey: lastRegisteredIdKey)
    }

    // MARK: - OSPushSubscriptionObserver

    nonisolated func onPushSubscriptionDidChange(state: OSPushSubscriptionChangedState) {
        let previousId = state.previous.id
        let currentId = state.current.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            // If OneSignal rotated to a new id (iOS APNs token
            // refresh after update / reinstall), tombstone the old
            // row on BE so we don't accumulate orphan rows per
            // device. Swallow errors — a missing row is fine, and
            // we'll register the new id regardless.
            if let previousId, !previousId.isEmpty, previousId != currentId {
                _ = try? await APIClient.shared.unregisterPushSubscription(subscriptionId: previousId)
            }
            if let currentId, !currentId.isEmpty {
                await self.register(currentId)
            }
        }
    }

    // MARK: - Internals

    private func register(_ subscriptionId: String) async {
        guard AuthStore.shared.isAuthenticated else { return }
        do {
            try await APIClient.shared.registerPushSubscription(subscriptionId: subscriptionId)
            UserDefaults.standard.set(subscriptionId, forKey: lastRegisteredIdKey)
        } catch {
            // Stay silent — the next observer tick or scene-active
            // tick will retry. Logging here would be noisy for
            // transient offline states.
        }
    }
}
