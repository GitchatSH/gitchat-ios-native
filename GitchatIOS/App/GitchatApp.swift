import SwiftUI
import UIKit
import FirebaseCore
import FirebaseAnalytics
import FacebookCore
import AppsFlyerLib

@main
struct GitchatApp: App {
    @StateObject private var auth = AuthStore.shared
    @StateObject private var socket = SocketClient.shared
    @StateObject private var store = StoreManager.shared
    @AppStorage("gitchat.pref.appearance") private var appearance: String = "system"
    @AppStorage("gitchat.pref.fontScale") private var fontScale: Double = 1.0

    init() {
        FirebaseApp.configure()
        Analytics.setAnalyticsCollectionEnabled(true)

        // Facebook SDK
        ApplicationDelegate.shared.application(
            UIApplication.shared,
            didFinishLaunchingWithOptions: nil
        )

        // AppsFlyer SDK — SKAdNetwork handles attribution without IDFA,
        // so we skip the ATT prompt entirely.
        AppsFlyerLib.shared().appsFlyerDevKey = "9PnQZkZDCb8dXSaRinRZAN"
        AppsFlyerLib.shared().appleAppID = "6762181976"

        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
        Task { @MainActor in
            StoreManager.shared.start()
            PushManager.shared.bootstrap()
            if let login = AuthStore.shared.login {
                PushManager.shared.identify(login: login)
            }
            PresenceStore.shared.start()
            AppsFlyerLib.shared().start()
        }
    }

    var body: some Scene {
        WindowGroup {
            rootContent
                .onAppear {
                    applyInterfaceStyle()
                    hideCatalystTitle()
                }
                .onChange(of: appearance) { _ in applyInterfaceStyle() }
                .onOpenURL { url in
                    // Gitchat-native deep links (invite etc.) short-circuit
                    // the Facebook SDK handler.
                    if AppRouter.shared.handleDeepLink(url) { return }
                    ApplicationDelegate.shared.application(
                        UIApplication.shared,
                        open: url,
                        sourceApplication: nil,
                        annotation: [UIApplication.OpenURLOptionsKey.annotation]
                    )
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Universal Link entry point. When BE serves AASA on
                    // gitchat.sh / dev.gitchat.sh, iOS hands the tapped
                    // https URL to us here — we route invite links to
                    // the preview sheet the same way as the custom scheme.
                    if let url = activity.webpageURL {
                        AppRouter.shared.handleDeepLink(url)
                    }
                }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        let base = RootView()
            .environmentObject(auth)
            .environmentObject(socket)
            .tint(Color("AccentColor"))
            .preferredColorScheme(colorScheme)
            .dynamicTypeSize(Self.dynamicType(for: fontScale))
            .toastHost()
        #if targetEnvironment(macCatalyst)
        // Mac windows need an explicit minimum size; iPhone should
        // never get any frame override or it stretches/clamps weirdly.
        base.frame(minWidth: 900, minHeight: 600)
        #else
        base
        #endif
    }

    private static func dynamicType(for scale: Double) -> DynamicTypeSize {
        switch scale {
        case ..<0.85: return .xSmall
        case ..<0.9:  return .small
        case ..<0.95: return .medium
        case ..<1.05: return .large
        case ..<1.15: return .xLarge
        case ..<1.25: return .xxLarge
        case ..<1.35: return .xxxLarge
        default:      return .accessibility1
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// On Catalyst, the Mac window's titlebar shows the current
    /// navigationTitle ("Settings", "Chats", etc). The titlebar row
    /// itself can't be removed (it holds the traffic lights — macOS
    /// chrome requirement). We make it as minimal as possible:
    /// - Hide the title text.
    /// - Use `.unifiedCompact` toolbar style so the bar is the
    ///   smallest height Catalyst allows.
    /// True transparent/overlay titlebar (traffic lights floating
    /// over content) would require switching the project to
    /// "Optimize Interface for Mac" mode.
    private func hideCatalystTitle() {
        #if targetEnvironment(macCatalyst)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.titlebar?.titleVisibility = .hidden
            windowScene.titlebar?.toolbarStyle = .unifiedCompact
            windowScene.titlebar?.autoHidesToolbarInFullScreen = true
        }
        #endif
    }

    /// Apply the stored appearance to every UIWindow's
    /// `overrideUserInterfaceStyle`. `.preferredColorScheme` alone
    /// doesn't propagate to sheet-owned windows, so the Settings sheet
    /// stays stuck on the last forced scheme. Forcing the style here
    /// covers the root window AND all sheet windows.
    private func applyInterfaceStyle() {
        let style: UIUserInterfaceStyle
        switch appearance {
        case "light": style = .light
        case "dark": style = .dark
        default: style = .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
