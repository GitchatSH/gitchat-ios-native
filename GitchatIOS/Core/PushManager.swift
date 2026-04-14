import Foundation
import UIKit
import OneSignalFramework

/// Deep-link targets the app knows how to route to.
enum PushRoute: Equatable {
    case conversation(id: String)
    case profile(login: String)
    case notifications
    case post(id: String)
}

@MainActor
final class PushManager: ObservableObject {
    static let shared = PushManager()

    static let oneSignalAppId = "bda62420-cf4d-4669-b5ed-829010c63adc"

    @Published var pendingRoute: PushRoute?

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
        OneSignal.Notifications.addClickListener(ClickListener { [weak self] event in
            Task { @MainActor in self?.handle(clickedNotification: event) }
        })
        initialized = true
    }

    func requestPermission() async {
        guard initialized else { return }
        await withCheckedContinuation { cont in
            OneSignal.Notifications.requestPermission({ _ in
                cont.resume()
            }, fallbackToSettings: true)
        }
    }

    func identify(login: String) {
        guard initialized else { return }
        OneSignal.login(login)
    }

    func forgetIdentity() {
        guard initialized else { return }
        OneSignal.logout()
    }

    private func handle(clickedNotification event: OSNotificationClickEvent) {
        let additional = event.notification.additionalData as? [String: Any] ?? [:]
        guard let type = additional["type"] as? String else { return }

        switch type {
        case "chat_message", "group_add", "reply", "mention":
            if let id = additional["conversation_id"] as? String, !id.isEmpty {
                pendingRoute = .conversation(id: id)
            }
        case "follow":
            if let login = additional["actor_login"] as? String, !login.isEmpty {
                pendingRoute = .profile(login: login)
            }
        case "reaction", "repo_starred", "event_like", "event_comment",
             "post_like", "post_reply", "awesome_list_milestone",
             "awesome_list_suggestion":
            pendingRoute = .notifications
        default:
            pendingRoute = .notifications
        }
    }
}

private final class ClickListener: NSObject, OSNotificationClickListener {
    let onClick: (OSNotificationClickEvent) -> Void

    init(_ onClick: @escaping (OSNotificationClickEvent) -> Void) {
        self.onClick = onClick
    }

    func onClick(event: OSNotificationClickEvent) {
        onClick(event)
    }
}
