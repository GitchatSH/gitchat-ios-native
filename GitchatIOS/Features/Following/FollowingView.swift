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

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.users.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    List(vm.users) { u in
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
                    }
                    .listStyle(.plain)
                    .refreshable { await vm.load() }
                }
            }
            .navigationTitle("Friends")
            .task { if vm.users.isEmpty { await vm.load() } }
        }
    }
}
