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
                    Text(p.name ?? p.login).font(.title2.bold())
                    Text("@\(p.login)").foregroundStyle(.secondary)
                    if let bio = p.bio { Text(bio).multilineTextAlignment(.center).padding(.horizontal) }
                    HStack(spacing: 24) {
                        stat("Followers", p.followers ?? 0)
                        stat("Following", p.following ?? 0)
                        stat("Repos", p.public_repos ?? 0)
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
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack { Text("\(value)").font(.title3.bold()); Text(label).font(.caption).foregroundStyle(.secondary) }
    }
}

struct MeView: View {
    @EnvironmentObject var auth: AuthStore
    var body: some View {
        NavigationStack {
            VStack {
                ProfileView()
                Button("Sign out", role: .destructive) { auth.signOut() }
                    .padding()
            }
            .navigationTitle("Me")
        }
    }
}
