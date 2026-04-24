import Foundation

/// Push-subscription registry endpoints. The backend stores
/// `(subscription_id, user_login)` pairs so it can target push
/// notifications by OneSignal subscription id directly rather than
/// via tag filters or external-id aliases — both of which drop
/// messages across app updates in practice.
extension APIClient {
    struct RegisterPushSubscriptionBody: Encodable {
        let subscription_id: String
        let platform: String
        let app_version: String?
    }

    func registerPushSubscription(subscriptionId: String) async throws {
        let body = RegisterPushSubscriptionBody(
            subscription_id: subscriptionId,
            platform: "ios",
            app_version: Config.appVersion
        )
        let _: EmptyResponse = try await request(
            "user/push-subscriptions",
            method: "POST",
            body: body
        )
    }

    func unregisterPushSubscription(subscriptionId: String) async throws {
        let encoded = subscriptionId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? subscriptionId
        let _: EmptyResponse = try await request(
            "user/push-subscriptions/\(encoded)",
            method: "DELETE"
        )
    }
}
