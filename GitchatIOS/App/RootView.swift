import SwiftUI
import StoreKit

private struct InviteCodeRoute: Identifiable {
    let code: String
    var id: String { code }
}

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
                MainTabView()
                    .task {
                        socket.connect()
                        if let login = auth.login { socket.subscribeUser(login: login) }
                        wireGlobalMessageBanner()
                        startHeartbeat()
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
        .sheet(item: Binding(
            get: { router.pendingInviteCode.map(InviteCodeRoute.init(code:)) },
            set: { router.pendingInviteCode = $0?.code }
        )) { route in
            InvitePreviewSheet(code: route.code)
        }
        .onChange(of: scenePhase) { phase in
            // Fresh heartbeat the moment the app comes back to the
            // foreground so the user's Redis TTL is refreshed immediately
            // instead of waiting up to 30s for the next scheduled tick.
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
            // Digest rule: rate-limit identical sender bursts to one
            // toast per 5 seconds per sender so rapid chat doesn't spam.
            let now = Date()
            let key = msg.sender
            if let last = Self.lastToastTimes[key], now.timeIntervalSince(last) < 5 {
                return
            }
            Self.lastToastTimes[key] = now
            let preview = msg.content.isEmpty ? "sent you a photo" : msg.content
            ToastCenter.shared.show(.info, "@\(msg.sender)", preview)
        }
    }

    nonisolated(unsafe) private static var lastToastTimes: [String: Date] = [:]

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                SocketClient.shared.emitPresenceHeartbeat()
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
                .tabItem { Label("Chats", image: "ChatTabIcon") }
                .tag(0)
            TeamsView()
                .macReadableWidth()
                .tabItem { Label("Teams", systemImage: "person.3.fill") }
                .tag(1)
            NotificationsView()
                .macReadableWidth()
                .tabItem { Label("Activity", systemImage: "bell.fill") }
                .tag(2)
            FollowingView()
                .macReadableWidth()
                .tabItem { Label("Friends", systemImage: "person.2.fill") }
                .tag(3)
            MeView()
                .macReadableWidth()
                .tabItem { Label("Me", systemImage: "person.crop.circle") }
                .tag(4)
        }
    }
}
