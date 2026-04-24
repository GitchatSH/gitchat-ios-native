import SwiftUI
import StoreKit
import UIKit

private struct InviteCodeRoute: Identifiable {
    let code: String
    var id: String { code }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var socket: SocketClient
    @StateObject private var push = PushManager.shared
    @StateObject private var router = AppRouter.shared
    @StateObject private var updater = AppUpdateChecker.shared
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @State private var heartbeatTask: Task<Void, Never>?
    @State private var updateSheetInfo: AppUpdateChecker.VersionInfo?

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
        .onReceive(NotificationCenter.default.publisher(for: .gitchatWaveResponded)) { note in
            guard let cid = note.object as? String, !cid.isEmpty else { return }
            ToastCenter.shared.show(.success, "Waved back — opening chat")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                AppRouter.shared.openConversation(id: cid)
            }
        }
        .onChange(of: scenePhase) { phase in
            // Fresh heartbeat the moment the app comes back to the
            // foreground so the user's Redis TTL is refreshed immediately
            // instead of waiting up to 30s for the next scheduled tick.
            if phase == .active, auth.isAuthenticated {
                PresenceStore.shared.heartbeatNow()
            }
            if phase == .active {
                Task { await updater.check() }
            }
        }
        .task { await updater.check() }
        .overlay(alignment: .top) {
            if case .updateAvailable(let info) = updater.state {
                UpdateBanner(
                    info: info,
                    onUpdate: { openUpdate(info) },
                    onSnooze: { updater.snoozeCurrent() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(9_000)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: updater.state)
        .fullScreenCover(isPresented: Binding(
            get: { if case .forceUpdateRequired = updater.state { return true } else { return false } },
            set: { _ in }
        )) {
            if case .forceUpdateRequired(let info) = updater.state {
                ForceUpdateView(info: info, onUpdate: { openUpdate(info) })
            }
        }
        .sheet(item: $updateSheetInfo) { info in
            AppStoreSheet(appStoreId: info.appStoreId)
                .ignoresSafeArea()
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

    /// Route an "update now" tap to the right destination. In-app
    /// App Store sheet when we're running a store build; external
    /// TestFlight/Safari deep-link for beta/sim builds (SKStoreProduct
    /// can't render those).
    private func openUpdate(_ info: AppUpdateChecker.VersionInfo) {
        switch UpdateSheetRouter.destination(for: info) {
        case .inAppSheet:
            updateSheetInfo = info
        case .external(let url):
            UIApplication.shared.open(url)
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
            DiscoverView()
                .macReadableWidth()
                .tabItem { Label("Discover", systemImage: "safari.fill") }
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
