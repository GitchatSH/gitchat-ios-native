import SwiftUI

@MainActor
final class FollowingViewModel: ObservableObject {
    @Published var users: [UserProfile] = []

    func load() async {
        do { users = try await APIClient.shared.followingList() } catch { }
    }
}

struct FollowingView: View {
    @StateObject private var vm = FollowingViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.users.isEmpty {
                    ContentUnavailableCompat(
                        title: "No friends yet",
                        systemImage: "person.2",
                        description: "People you follow on GitHub show up here."
                    )
                } else {
                    List(vm.users, id: \.login) { u in
                        NavigationLink {
                            ProfileView(login: u.login)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(url: u.avatar_url, size: 40)
                                VStack(alignment: .leading) {
                                    Text(u.name ?? u.login).font(.headline)
                                    Text("@\(u.login)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await vm.load() }
                }
            }
            .navigationTitle("Friends")
            .task { await vm.load() }
        }
    }
}
