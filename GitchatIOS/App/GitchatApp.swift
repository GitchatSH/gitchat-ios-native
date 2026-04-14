import SwiftUI

@main
struct GitchatApp: App {
    @StateObject private var auth = AuthStore.shared
    @StateObject private var socket = SocketClient.shared
    @AppStorage("gitchat.pref.appearance") private var appearance: String = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(socket)
                .tint(.accentColor)
                .preferredColorScheme(colorScheme)
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
