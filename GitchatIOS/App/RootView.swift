import SwiftUI
import StoreKit

struct RootView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var socket: SocketClient
    @StateObject private var push = PushManager.shared
    @StateObject private var router = AppRouter.shared
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @State private var heartbeatTask: Task<Void, Never>?

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
                            wireGlobalMessageBanner()
                            startHeartbeat()
                        }
                }
            } else {
                SignInView()
            }
        }
        .sheet(item: Binding(
            get: { router.pendingProfileLogin.map(ProfileLoginRoute.init(login:)) },
            set: { router.pendingProfileLogin = $0?.login }
        )) { route in
            NavigationStack { ProfileView(login: route.login) }
        }
        .onChange(of: scenePhase) { phase in
            // Fresh heartbeat the moment the app comes back to the
            // foreground so `last_seen_at` in the DB is up to date.
            if phase == .active, auth.isAuthenticated {
                PresenceStore.shared.heartbeatNow()
            }
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

    private func wireGlobalMessageBanner() {
        socket.globalOnMessageSent = { msg in
            // Skip own messages and the conversation currently on screen.
            guard msg.sender != auth.login else { return }
            if let active = socket.currentConversationId,
               active == msg.conversation_id {
                return
            }
            let preview = msg.content.isEmpty ? "sent you a photo" : msg.content
            ToastCenter.shared.show(.info, "@\(msg.sender)", preview)
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
    @StateObject private var router = AppRouter.shared

    var body: some View {
        TabView(selection: Binding(
            get: { router.selectedTab },
            set: { newValue in
                if newValue != router.selectedTab { Haptics.selection() }
                router.selectedTab = newValue
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
