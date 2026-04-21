import Foundation
import FirebaseAnalytics
import FacebookCore
import AppsFlyerLib

/// Unified tracker that fires standard events to Firebase Analytics,
/// Meta Facebook SDK, and AppsFlyer at once.
enum AnalyticsTracker {
    // MARK: - Lifecycle

    static func trackAppOpen(source: String? = nil) {
        Analytics.logEvent(AnalyticsEventAppOpen, parameters: nil)
        AppsFlyerLib.shared().logEvent(AFEventOpenedFromPushNotification, withValues: source.map { ["source": $0] } ?? [:])
    }

    static func setUserID(_ login: String) {
        Analytics.setUserID(login)
        AppEvents.shared.userID = login
        AppsFlyerLib.shared().customerUserID = login
    }

    static func clearUserID() {
        Analytics.setUserID(nil)
        AppEvents.shared.userID = nil
        AppsFlyerLib.shared().customerUserID = nil
    }

    // MARK: - Auth

    static func trackSignUp(method: String) {
        Analytics.logEvent(AnalyticsEventSignUp, parameters: [AnalyticsParameterMethod: method])
        AppEvents.shared.logEvent(
            .completedRegistration,
            parameters: [AppEvents.ParameterName.registrationMethod: method as Any]
        )
        AppsFlyerLib.shared().logEvent(AFEventCompleteRegistration, withValues: [
            AFEventParamRegistrationMethod: method
        ])
    }

    static func trackLogin(method: String) {
        Analytics.logEvent(AnalyticsEventLogin, parameters: [AnalyticsParameterMethod: method])
        AppEvents.shared.logEvent(AppEvents.Name("fb_mobile_login"))
        AppsFlyerLib.shared().logEvent(AFEventLogin, withValues: [
            "method": method
        ])
    }

    // MARK: - Messaging

    static func trackMessageSent(conversationId: String, isGroup: Bool, hasAttachment: Bool) {
        let params: [String: Any] = [
            "conversation_id": conversationId,
            "is_group": isGroup,
            "has_attachment": hasAttachment
        ]
        Analytics.logEvent("message_sent", parameters: params)
        AppEvents.shared.logEvent(AppEvents.Name("message_sent"))
        AppsFlyerLib.shared().logEvent("af_message_sent", withValues: params)
    }

    static func trackConversationStarted(isGroup: Bool) {
        let params: [String: Any] = ["is_group": isGroup]
        Analytics.logEvent("conversation_started", parameters: params)
        AppEvents.shared.logEvent(AppEvents.Name("conversation_started"))
        AppsFlyerLib.shared().logEvent("af_conversation_started", withValues: params)
    }

    // MARK: - Social

    static func trackFollow(login: String) {
        let params: [String: Any] = ["target_login": login]
        Analytics.logEvent("follow_user", parameters: params)
        AppEvents.shared.logEvent(AppEvents.Name("follow_user"))
        AppsFlyerLib.shared().logEvent("af_follow", withValues: params)
    }

    static func trackProfileView(login: String) {
        Analytics.logEvent(AnalyticsEventViewItem, parameters: [
            AnalyticsParameterItemID: "profile:\(login)",
            AnalyticsParameterContentType: "profile"
        ])
        AppEvents.shared.logEvent(.viewedContent, parameters: [
            AppEvents.ParameterName.contentType: "profile" as Any,
            AppEvents.ParameterName.contentID: login as Any
        ])
        AppsFlyerLib.shared().logEvent(AFEventContentView, withValues: [
            AFEventParamContentType: "profile",
            AFEventParamContentId: login
        ])
    }

    static func trackSearch(query: String) {
        Analytics.logEvent(AnalyticsEventSearch, parameters: [AnalyticsParameterSearchTerm: query])
        AppEvents.shared.logEvent(.searched, parameters: [
            AppEvents.ParameterName.searchString: query as Any
        ])
        AppsFlyerLib.shared().logEvent(AFEventSearch, withValues: [AFEventParamSearchString: query])
    }

    // MARK: - Reactions / Channels

    static func trackReaction(emoji: String) {
        let params: [String: Any] = ["emoji": emoji]
        Analytics.logEvent("message_reaction", parameters: params)
        AppEvents.shared.logEvent(AppEvents.Name("message_reaction"))
        AppsFlyerLib.shared().logEvent("af_message_reaction", withValues: params)
    }

    static func trackChannelSubscribe(channelId: String) {
        let params: [String: Any] = ["channel_id": channelId]
        Analytics.logEvent("channel_subscribe", parameters: params)
        AppEvents.shared.logEvent(AppEvents.Name("channel_subscribe"))
        AppsFlyerLib.shared().logEvent(AFEventSubscribe, withValues: params)
    }

    // MARK: - Monetisation

    static func trackPurchase(productId: String, price: Double, currency: String) {
        Analytics.logEvent(AnalyticsEventPurchase, parameters: [
            AnalyticsParameterItemID: productId,
            AnalyticsParameterValue: price,
            AnalyticsParameterCurrency: currency
        ])
        AppEvents.shared.logPurchase(
            amount: price,
            currency: currency,
            parameters: [AppEvents.ParameterName.contentID: productId as Any]
        )
        AppsFlyerLib.shared().logEvent(AFEventPurchase, withValues: [
            AFEventParamRevenue: price,
            AFEventParamCurrency: currency,
            AFEventParamContentId: productId
        ])
    }

    static func trackInitiatedCheckout(productId: String) {
        Analytics.logEvent("begin_checkout", parameters: [AnalyticsParameterItemID: productId])
        AppEvents.shared.logEvent(.initiatedCheckout, parameters: [
            AppEvents.ParameterName.contentID: productId as Any
        ])
        AppsFlyerLib.shared().logEvent(AFEventInitiatedCheckout, withValues: [
            AFEventParamContentId: productId
        ])
    }

    // MARK: - Navigation

    static func trackScreen(_ name: String) {
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: name
        ])
        AppEvents.shared.logEvent(AppEvents.Name("screen_view"))
    }
}
