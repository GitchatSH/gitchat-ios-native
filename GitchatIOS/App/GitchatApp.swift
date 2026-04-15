import SwiftUI
import UIKit

@main
struct GitchatApp: App {
    @StateObject private var auth = AuthStore.shared
    @StateObject private var socket = SocketClient.shared
    @StateObject private var store = StoreManager.shared
    @AppStorage("gitchat.pref.appearance") private var appearance: String = "system"

    init() {
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
        Task { @MainActor in
            StoreManager.shared.start()
            PushManager.shared.bootstrap()
            PresenceStore.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(socket)
                .tint(.accentColor)
                .preferredColorScheme(colorScheme)
                .toastHost()
                .onAppear { applyInterfaceStyle() }
                .onChange(of: appearance) { _ in applyInterfaceStyle() }
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
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
