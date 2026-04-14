import SwiftUI

@MainActor
final class FollowingViewModel: ObservableObject {
    @Published var users: [FriendUser] = []
    @Published var isLoading = false
    @Published var error: String?

    func load() async {
        isLoading = true; defer { isLoading = false }
        do { users = try await APIClient.shared.followingList() }
        catch { self.error = error.localizedDescription }
    }
}

struct FollowingView: View {
    @StateObject private var vm = FollowingViewModel()
    @State private var filter = ""

    private var filtered: [FriendUser] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return vm.users }
        return vm.users.filter { u in
            u.login.lowercased().contains(q)
                || (u.name ?? "").lowercased().contains(q)
        }
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
                } else {
                    List(filtered) { u in
                        NavigationLink {
                            ProfileView(login: u.login)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(url: u.avatar_url, size: 40)
                                VStack(alignment: .leading) {
                                    Text(u.name ?? u.login).font(.headline)
                                    Text("@\(u.login)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if u.online == true {
                                    Circle().fill(.green).frame(width: 8, height: 8)
                                }
                            }
                        }
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .refreshable { await vm.load() }
                }
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search friends")
            .navigationTitle("Friends")
            .task { if vm.users.isEmpty { await vm.load() } }
        }
    }
}
