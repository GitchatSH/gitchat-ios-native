import SwiftUI

@main
struct GitchatApp: App {
    @StateObject private var auth = AuthStore.shared
    @StateObject private var socket = SocketClient.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(socket)
                .tint(.accentColor)
                .preferredColorScheme(nil)
        }
    }
}
