import SwiftUI

@MainActor
final class FollowingViewModel: ObservableObject {
    @Published var users: [FriendUser] = []
    @Published var isLoading = false
    @Published var isSyncing = false
    @Published var error: String?

    func load() async {
        isLoading = true; defer { isLoading = false }
        do { users = try await APIClient.shared.followingList() }
        catch { self.error = error.localizedDescription }
    }

    func syncGitHubFollows(silent: Bool = false) async {
        isSyncing = true
        let started = Date()
        defer {
            // Keep the syncing indicator visible for at least 2s so the
            // user notices the sync happened, mirroring ConversationsViewModel.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 2 {
                let remaining = 2 - elapsed
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    self?.isSyncing = false
                }
            } else {
                isSyncing = false
            }
        }
        do {
            try await APIClient.shared.syncGitHubFollows()
            await load()
            if !silent {
                ToastCenter.shared.show(.success, "Synced", "Pulled your latest GitHub follows.")
            }
        } catch {
            if !silent {
                ToastCenter.shared.show(.error, "Sync failed", error.localizedDescription)
            }
        }
    }
}

struct FollowingView: View {
    @StateObject private var vm = FollowingViewModel()
    @State private var filter = ""
    @State private var showExplore = false
    @ObservedObject private var presence = PresenceStore.shared

    private var filtered: [FriendUser] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [FriendUser]
        if q.isEmpty {
            base = vm.users
        } else {
            base = vm.users.filter { u in
                u.login.lowercased().contains(q)
                    || (u.name ?? "").lowercased().contains(q)
            }
        }
        // Online-first, each group alphabetical by login.
        let online = base
            .filter { presence.isOnline($0.login) }
            .sorted { $0.login.lowercased() < $1.login.lowercased() }
        let offline = base
            .filter { !presence.isOnline($0.login) }
            .sorted { $0.login.lowercased() < $1.login.lowercased() }
        return online + offline
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.users.isEmpty {
                    SkeletonList(count: 10, avatarSize: 40)
                } else if let err = vm.error, vm.users.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Couldn't load friends").font(.headline)
                        Text(err).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal)
                        Button("Retry") { Task { await vm.load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.users.isEmpty {
                    ContentUnavailableCompat(
                        title: "No friends yet",
                        systemImage: "person.2",
                        description: "People you follow on GitHub show up here."
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableCompat(
                        title: "No results",
                        systemImage: "magnifyingglass",
                        description: "Try a different search."
                    )
                } else {
                    List(filtered) { u in
                        NavigationLink {
                            ProfileView(login: u.login)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(url: u.avatar_url, size: 40, login: u.login)
                                VStack(alignment: .leading) {
                                    Text(u.name ?? u.login).font(.headline)
                                    Text("@\(u.login)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.hidden)
                    .refreshable { await vm.load() }
                }
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search friends")
            .navigationTitle("Friends")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if vm.isSyncing {
                        SyncingIndicator()
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showExplore = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showExplore) {
                ExploreSheet()
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.isSyncing)
            .task {
                if vm.users.isEmpty { await vm.load() }
                // Pull latest GitHub follows automatically so new
                // followers show up without tapping the sync icon.
                await vm.syncGitHubFollows(silent: true)
                presence.ensure(vm.users.map(\.login))
            }
            .onChange(of: vm.users.count) { _ in
                presence.ensure(vm.users.map(\.login))
            }
        }
    }
}
