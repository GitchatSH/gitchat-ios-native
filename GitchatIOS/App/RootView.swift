import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var socket: SocketClient
    @State private var heartbeatTask: Task<Void, Never>?

    var body: some View {
        Group {
            if auth.isAuthenticated {
                MainTabView()
                    .task {
                        socket.connect()
                        startHeartbeat()
                    }
            } else {
                SignInView()
            }
        }
        .onChange(of: auth.isAuthenticated) { isAuth in
            if isAuth {
                socket.connect()
                startHeartbeat()
            } else {
                socket.disconnect()
                heartbeatTask?.cancel()
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await APIClient.shared.heartbeat()
                try? await Task.sleep(nanoseconds: UInt64(Config.presenceHeartbeatSeconds * 1_000_000_000))
            }
        }
    }
}

struct MainTabView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            ConversationsListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(0)
            ChannelsView()
                .tabItem { Label("Channels", systemImage: "number") }
                .tag(1)
            NotificationsView()
                .tabItem { Label("Activity", systemImage: "bell.fill") }
                .tag(2)
            FollowingView()
                .tabItem { Label("Friends", systemImage: "person.2.fill") }
                .tag(3)
            MeView()
                .tabItem { Label("Me", systemImage: "person.crop.circle") }
                .tag(4)
        }
    }
}
