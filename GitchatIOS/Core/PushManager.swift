import Foundation
import OneSignalFramework

@MainActor
final class PushManager {
    static let shared = PushManager()

    /// Paste your OneSignal App ID here (Settings → Keys & IDs). Leave the
    /// placeholder string if you haven't created the app yet — PushManager
    /// will quietly skip initialization.
    static let oneSignalAppId = "bda62420-cf4d-4669-b5ed-829010c63adc"

    private var initialized = false

    private init() {}

    func bootstrap(launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) {
        guard !initialized else { return }
        guard Self.oneSignalAppId != "PASTE_YOUR_ONESIGNAL_APP_ID",
              !Self.oneSignalAppId.isEmpty else {
            return
        }
        OneSignal.Debug.setLogLevel(.LL_WARN)
        OneSignal.initialize(Self.oneSignalAppId, withLaunchOptions: launchOptions)
        initialized = true
    }

    /// Ask the user for push permission. Safe to call multiple times — iOS
    /// only shows the prompt once.
    func requestPermission() async {
        guard initialized else { return }
        await withCheckedContinuation { cont in
            OneSignal.Notifications.requestPermission({ _ in
                cont.resume()
            }, fallbackToSettings: true)
        }
    }

    /// Link the current user's GitHub login to OneSignal so the backend
    /// can target pushes by external id.
    func identify(login: String) {
        guard initialized else { return }
        OneSignal.login(login)
    }

    func forgetIdentity() {
        guard initialized else { return }
        OneSignal.logout()
    }
}

import UIKit
