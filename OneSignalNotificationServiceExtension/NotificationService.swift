import UserNotifications
import OneSignalExtension
import Intents

final class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var receivedRequest: UNNotificationRequest!
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.receivedRequest = request
        self.contentHandler = contentHandler
        self.bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let bestAttemptContent = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        // Let OneSignal first decrypt + enrich (attachments, action buttons).
        OneSignalExtension.didReceiveNotificationExtensionRequest(
            request,
            with: bestAttemptContent
        ) { [weak self] processed in
            // Attempt to upgrade to a Communication Notification (big avatar
            // + small app icon) when we have a sender login in the payload.
            let finalContent = self?.applyCommunicationIntent(to: processed) ?? processed
            contentHandler(finalContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            OneSignalExtension.serviceExtensionTimeWillExpireRequest(
                receivedRequest,
                with: bestAttemptContent
            )
            contentHandler(bestAttemptContent)
        }
    }

    /// Upgrade a notification to a Communication Notification when we have a
    /// `sender_login` / `sender_avatar_url` in the payload. On iOS 15+ this
    /// makes the notification render with the sender's avatar as the hero
    /// and the app icon as a small corner badge.
    private func applyCommunicationIntent(to content: UNNotificationContent) -> UNNotificationContent {
        guard #available(iOS 15.0, *) else { return content }

        // Pull custom data — OneSignal nests under `custom.a`.
        let userInfo = content.userInfo
        let custom = (userInfo["custom"] as? [String: Any]) ?? [:]
        let data = (custom["a"] as? [String: Any]) ?? (userInfo["data"] as? [String: Any]) ?? [:]

        guard
            let senderLogin = (data["sender_login"] as? String) ?? (data["actor_login"] as? String),
            !senderLogin.isEmpty
        else {
            return content
        }

        // Group chats: keep the backend-set title ("sender → groupName")
        // as-is. iOS Communication Notification's group layout replaces
        // the title with the sender's name and demotes the group name
        // to a subtitle, which isn't the Telegram-style banner we want.
        let isGroupBool = (data["is_group"] as? Bool) == true
            || (data["is_group"] as? NSNumber)?.boolValue == true
            || (data["is_group"] as? String) == "true"
        let groupNameString = (data["group_name"] as? String) ?? ""
        if isGroupBool && !groupNameString.isEmpty {
            return content
        }

        let senderName = (data["sender_name"] as? String) ?? senderLogin
        let avatarURLString = (data["sender_avatar_url"] as? String)
            ?? "https://github.com/\(senderLogin).png"

        // Build an INPerson with an INImage (downloaded synchronously — small
        // network cost in the NSE is acceptable because the system gives us
        // up to 30 s).
        let avatarImage: INImage?
        if let url = URL(string: avatarURLString),
           let data = try? Data(contentsOf: url) {
            avatarImage = INImage(imageData: data)
        } else {
            avatarImage = nil
        }

        let handle = INPersonHandle(value: senderLogin, type: .unknown)
        let sender = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: senderName,
            image: avatarImage,
            contactIdentifier: nil,
            customIdentifier: senderLogin
        )

        let intent = INSendMessageIntent(
            recipients: nil,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: (data["conversation_id"] as? String) ?? senderLogin,
            serviceName: nil,
            sender: sender
        )

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        do {
            return try content.updating(from: intent)
        } catch {
            return content
        }
    }
}
