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
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
