import SwiftUI

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var profile: UserProfile?
    @Published var error: String?
    let login: String?

    init(login: String? = nil) { self.login = login }

    func load() async {
        do {
            if let login {
                profile = try await APIClient.shared.userProfile(login: login)
            } else {
                profile = try await APIClient.shared.myProfile()
            }
        } catch { self.error = error.localizedDescription }
    }
}

enum FollowListKind: Identifiable {
    case followers(String)
    case following(String)
    var id: String {
        switch self {
        case .followers(let l): return "followers:\(l)"
        case .following(let l): return "following:\(l)"
        }
    }
    var title: String {
        switch self {
        case .followers: return "Followers"
        case .following: return "Following"
        }
    }
}

struct ProfileView: View {
    @StateObject private var vm: ProfileViewModel
    @StateObject private var store = StoreManager.shared
    @State private var showUpgrade = false
    @State private var followList: FollowListKind?
    @State private var chatSheet: Conversation?
    @State private var startingChat = false
    @State private var followState: FollowStatus?
    @State private var followBusy = false
    @State private var showReport = false
    @State private var reportReason = "Spam"
    @State private var reportDetail = ""
    @State private var showBlockConfirm = false
    @StateObject private var blocks = BlockStore.shared

    /// True when viewing your own profile (no login passed).
    private var isSelf: Bool {
        if vm.login == nil { return true }
        if let me = AuthStore.shared.login, let login = vm.login,
           me.lowercased() == login.lowercased() { return true }
        return false
    }

    init(login: String? = nil) {
        _vm = StateObject(wrappedValue: ProfileViewModel(login: login))
    }

    var body: some View {
        ScrollView {
            if let err = vm.error, vm.profile == nil {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Couldn't load profile").font(.headline)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                    Button("Retry") { Task { await vm.load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 60)
            } else if let p = vm.profile {
                VStack(spacing: 16) {
                    AvatarView(url: p.avatar_url, size: 96, login: p.login)
                        .padding(.top)
                    HStack(spacing: 8) {
                        Text(p.name ?? p.login).font(.title2.bold())
                        if isSelf && store.isPro {
                            proBadge
                        }
                    }
                    Text("@\(p.login)").foregroundStyle(.secondary)
                    if let bio = p.bio { Text(bio).multilineTextAlignment(.center).padding(.horizontal) }
                    HStack(spacing: 24) {
                        Button { followList = .followers(p.login) } label: {
                            stat("Followers", p.followers ?? 0)
                        }
                        .buttonStyle(.plain)
                        Button { followList = .following(p.login) } label: {
                            stat("Following", p.following ?? 0)
                        }
                        .buttonStyle(.plain)
                        stat("Repos", p.public_repos ?? 0)
                    }
                    if !isSelf {
                        HStack(spacing: 6) {
                            Button {
                                Task { await toggleFollow(login: p.login) }
                            } label: {
                                followButtonLabel
                            }
                            .disabled(followBusy || followState == nil)

                            Button {
                                Task { await startChat(with: p.login) }
                            } label: {
                                actionLabel(
                                    systemImage: startingChat ? "hourglass" : "paperplane.fill",
                                    title: "Chat"
                                )
                            }
                            .disabled(startingChat)

                            Menu {
                                ShareLink(
                                    item: URL(string: "https://gitstar.ai/\(p.login)")!,
                                    subject: Text("@\(p.login) on Gitstar"),
                                    message: Text("Check out @\(p.login) on Gitstar")
                                ) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                if followState?.following == true {
                                    Button {
                                        Task { await toggleFollow(login: p.login) }
                                    } label: {
                                        Label("Unfollow", systemImage: "person.badge.minus")
                                    }
                                }
                                if blocks.isBlocked(p.login) {
                                    Button {
                                        blocks.unblock(p.login)
                                        ToastCenter.shared.show(.success, "Unblocked", "@\(p.login)")
                                    } label: {
                                        Label("Unblock", systemImage: "hand.raised.slash")
                                    }
                                } else {
                                    Button {
                                        showBlockConfirm = true
                                    } label: {
                                        Label("Block", systemImage: "hand.raised")
                                    }
                                }
                                Button {
                                    showReport = true
                                } label: {
                                    Label("Report", systemImage: "exclamationmark.bubble")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(width: 44, height: 40)
                                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                            }
                            .tint(.primary)
                        }
                        .padding(.horizontal)
                    }
                    if isSelf && !store.isPro {
                        upgradeCard
                    }
                    if let repos = p.top_repos, !repos.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Top Repositories").font(.headline).padding(.horizontal)
                            ForEach(repos) { r in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.full_name).font(.subheadline.bold())
                                    if let d = r.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                                .padding(.horizontal)
                            }
                        }
                    }
                }
            } else {
                ProfileSkeleton()
            }
        }
        #if !targetEnvironment(macCatalyst)
            .scrollIndicators(.hidden)
            #endif
        .task {
            await vm.load()
            if !isSelf, let login = vm.profile?.login ?? vm.login {
                await loadFollowStatus(login: login)
            }
        }
        .toolbar {
            if !isSelf, let login = vm.profile?.login ?? vm.login {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Link(destination: URL(string: "https://github.com/\(login)")!) {
                        Image("GitHubMark")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .foregroundStyle(Color(.label))
                    }
                    .accessibilityLabel("Open on GitHub")
                }
            }
        }
        .alert("Block @\(vm.profile?.login ?? "")?", isPresented: $showBlockConfirm) {
            Button("Block", role: .destructive) {
                if let l = vm.profile?.login {
                    blocks.block(l)
                    ToastCenter.shared.show(.warning, "Blocked", "@\(l)")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see their messages anywhere in the app.")
        }
        .sheet(isPresented: $showReport) {
            NavigationStack {
                Form {
                    Section("Reason") {
                        Picker("Reason", selection: $reportReason) {
                            Text("Spam").tag("Spam")
                            Text("Harassment").tag("Harassment")
                            Text("Impersonation").tag("Impersonation")
                            Text("Other").tag("Other")
                        }
                    }
                    Section("Details (optional)") {
                        TextField("Add context", text: $reportDetail, axis: .vertical)
                            .lineLimit(3...6)
                    }
                }
                .navigationTitle("Report user")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showReport = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            if let l = vm.profile?.login {
                                Task {
                                    do {
                                        try await APIClient.shared.reportUser(login: l, reason: reportReason, detail: reportDetail.isEmpty ? nil : reportDetail)
                                        ToastCenter.shared.show(.success, "Report sent", "Thanks for keeping Gitchat safe.")
                                    } catch {
                                        ToastCenter.shared.show(
                                            .error,
                                            "Couldn't send report",
                                            "Please try again in a moment."
                                        )
                                    }
                                }
                            }
                            showReport = false
                            reportDetail = ""
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showUpgrade) { UpgradeView() }
        .sheet(item: $chatSheet) { convo in
            NavigationStack { ChatDetailView(conversation: convo) }
        }
        .sheet(item: $followList) { kind in
            NavigationStack {
                FollowListSheet(kind: kind)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var followButtonLabel: some View {
        let following = followState?.following == true
        return Text(following ? "Following" : "Follow")
            .font(.geist(14, weight: .semibold))
            .foregroundStyle(following ? Color(.label) : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                (following ? Color(.secondarySystemBackground) : Color.accentColor),
                in: .rect(cornerRadius: 12)
            )
    }

    private func loadFollowStatus(login: String) async {
        do { followState = try await APIClient.shared.followStatus(login: login) }
        catch { }
    }

    private func toggleFollow(login: String) async {
        guard !followBusy else { return }
        followBusy = true; defer { followBusy = false }
        Haptics.impact(.light)
        let currentlyFollowing = followState?.following == true
        do {
            if currentlyFollowing {
                try await APIClient.shared.unfollow(login: login)
                ToastCenter.shared.show(.info, "Unfollowed", "@\(login)")
            } else {
                try await APIClient.shared.follow(login: login)
                ToastCenter.shared.show(.success, "Following", "@\(login)")
            }
            await loadFollowStatus(login: login)
        } catch {
            ToastCenter.shared.show(.error, "Couldn't update follow", error.localizedDescription)
        }
    }

    private func startChat(with login: String) async {
        startingChat = true
        defer { startingChat = false }
        Haptics.impact(.light)
        do {
            let convo = try await APIClient.shared.createConversation(recipient: login)
            Haptics.success()
            chatSheet = convo
        } catch {
            ToastCenter.shared.show(.error, "Couldn't start chat", error.localizedDescription)
        }
    }

    private func actionLabel(systemImage: String, title: String) -> some View {
        Text(title)
            .font(.geist(14, weight: .semibold))
            .foregroundStyle(Color(.label))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack { Text("\(value)").font(.title3.bold()); Text(label).font(.caption).foregroundStyle(.secondary) }
    }

    private var proBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill").font(.system(size: 10))
            Text("PRO").font(.system(size: 11, weight: .heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(
            LinearGradient(
                colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(Capsule())
    }

    private var upgradeCard: some View {
        Button {
            showUpgrade = true
        } label: {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upgrade to Pro")
                            .font(.geist(16, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Unlimited history, larger uploads, custom themes, Pro badge.")
                            .font(.geist(12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.3), radius: 10, y: 4)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }
}

struct ProfileSkeleton: View {
    var body: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(Color(.secondarySystemBackground))
                .frame(width: 96, height: 96)
                .padding(.top)
            SkeletonShape().frame(width: 140, height: 16)
            SkeletonShape().frame(width: 100, height: 12)
            SkeletonShape().frame(maxWidth: 260).frame(height: 10).padding(.horizontal)
            HStack(spacing: 24) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(spacing: 6) {
                        SkeletonShape().frame(width: 40, height: 14)
                        SkeletonShape().frame(width: 60, height: 10)
                    }
                }
            }
            HStack(spacing: 12) {
                SkeletonShape(cornerRadius: 12).frame(height: 40)
                SkeletonShape(cornerRadius: 12).frame(height: 40)
                SkeletonShape(cornerRadius: 12).frame(width: 44, height: 40)
            }
            .padding(.horizontal)
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonShape(cornerRadius: 12).frame(height: 56).padding(.horizontal)
                }
            }
        }
        .shimmering()
    }
}

@MainActor
final class FollowListVM: ObservableObject {
    @Published var users: [FriendUser] = []
    @Published var isLoading = false
    @Published var error: String?

    func load(kind: FollowListKind) async {
        isLoading = true; defer { isLoading = false }
        do {
            switch kind {
            case .followers(let login):
                users = try await APIClient.shared.followersList(login: login)
            case .following(let login):
                users = try await APIClient.shared.followingList(login: login)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct FollowListSheet: View {
    let kind: FollowListKind
    @StateObject private var vm = FollowListVM()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if vm.isLoading && vm.users.isEmpty {
                SkeletonList(count: 10, avatarSize: 40)
            } else if let err = vm.error, vm.users.isEmpty {
                ContentUnavailableCompat(
                    title: "Couldn't load",
                    systemImage: "exclamationmark.triangle",
                    description: err
                )
            } else if vm.users.isEmpty {
                ContentUnavailableCompat(
                    title: "Nobody here",
                    systemImage: "person.2",
                    description: "Nothing to show yet."
                )
            } else {
                List(vm.users) { u in
                    NavigationLink {
                        ProfileView(login: u.login)
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(url: u.avatar_url, size: 40, login: u.login)
                            VStack(alignment: .leading) {
                                Text(u.name ?? u.login).font(.headline)
                                Text("@\(u.login)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task { await vm.load(kind: kind) }
    }
}

struct MeView: View {
    @EnvironmentObject var auth: AuthStore
    @State private var showSettings = false
    @AppStorage("gitchat.pref.appearance") private var appearance: String = "system"

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        NavigationStack {
            ProfileView()
                .navigationTitle("Me")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if let login = auth.login,
                           let url = URL(string: "https://gitstar.ai/\(login)") {
                            ShareLink(
                                item: url,
                                subject: Text("@\(login) on Gitstar"),
                                message: Text("Chat with @\(login) on Gitstar")
                            ) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share profile")
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        SettingsView()
                            .toolbar {
                                ToolbarItem(placement: .navigationBarTrailing) {
                                    Button("Done") { showSettings = false }
                                }
                            }
                    }
                    // Re-apply the app-wide appearance to the sheet
                    // scene so changing Theme in Settings updates the
                    // Settings background immediately. `.id(appearance)`
                    // forces a rebuild when the value changes —
                    // `.preferredColorScheme(nil)` alone doesn't reset
                    // a previously forced override on the sheet scene.
                    .preferredColorScheme(colorScheme)
                    .id(appearance)
                }
        }
    }
}
