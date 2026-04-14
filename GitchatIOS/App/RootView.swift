import SwiftUI
import StoreKit

struct RootView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var socket: SocketClient
    @StateObject private var push = PushManager.shared
    @Environment(\.requestReview) private var requestReview
    @State private var heartbeatTask: Task<Void, Never>?
    @State private var routedConversationId: String?
    @State private var routedProfileLogin: String?

    var body: some View {
        Group {
            if auth.isAuthenticated {
                if auth.needsGithubLink {
                    LinkGithubWall()
                } else {
                    MainTabView()
                        .task {
                            socket.connect()
                            if let login = auth.login { socket.subscribeUser(login: login) }
                            startHeartbeat()
                        }
                }
            } else {
                SignInView()
            }
        }
        .sheet(item: Binding(
            get: { routedProfileLogin.map(ProfileLoginRoute.init(login:)) },
            set: { routedProfileLogin = $0?.login }
        )) { route in
            NavigationStack { ProfileView(login: route.login) }
        }
        .onChange(of: push.pendingRoute) { route in
            guard let route else { return }
            switch route {
            case .profile(let login):
                routedProfileLogin = login
            default: break
            }
            push.pendingRoute = nil
        }
        .onChange(of: auth.isAuthenticated) { isAuth in
            if isAuth {
                socket.connect()
                if let login = auth.login { socket.subscribeUser(login: login) }
                startHeartbeat()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    requestReview()
                }
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
        TabView(selection: Binding(
            get: { selection },
            set: { newValue in
                if newValue != selection { Haptics.selection() }
                selection = newValue
            }
        )) {
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
