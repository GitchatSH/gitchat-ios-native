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

struct ProfileView: View {
    @StateObject private var vm: ProfileViewModel
    @StateObject private var store = StoreManager.shared
    @State private var showUpgrade = false

    /// True when viewing your own profile (no login passed).
    private var isSelf: Bool { vm.login == nil }

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
                    AvatarView(url: p.avatar_url, size: 96)
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
                        stat("Followers", p.followers ?? 0)
                        stat("Following", p.following ?? 0)
                        stat("Repos", p.public_repos ?? 0)
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
                ProgressView().padding()
            }
        }
        .task { await vm.load() }
        .sheet(isPresented: $showUpgrade) { UpgradeView() }
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

struct MeView: View {
    @EnvironmentObject var auth: AuthStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ProfileView()
                .navigationTitle("Me")
                .toolbar {
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
                }
        }
    }
}
