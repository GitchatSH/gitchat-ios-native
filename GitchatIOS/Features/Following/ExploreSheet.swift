import SwiftUI

struct ExploreSheet: View {
    @State private var users: [APIClient.YouMightKnowUser] = []
    @State private var isLoading = true
    @State private var followedLogins: Set<String> = []
    @State private var pendingFollow: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    SkeletonList(count: 8, avatarSize: 40)
                } else if users.isEmpty {
                    ContentUnavailableCompat(
                        title: "No suggestions yet",
                        systemImage: "person.2",
                        description: "Follow more people to get suggestions."
                    )
                } else {
                    List(users) { u in
                        HStack(spacing: 12) {
                            AvatarView(url: u.avatar_url, size: 40, login: u.login)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(u.name ?? u.login)
                                    .font(.subheadline.weight(.semibold))
                                Text("@\(u.login)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(u.mutual_count) mutual friend\(u.mutual_count == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            followButton(for: u.login)
                        }
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    #if !targetEnvironment(macCatalyst)
            .scrollIndicators(.hidden)
            #endif
                }
            }
            .navigationTitle("You might know")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func followButton(for login: String) -> some View {
        let isFollowed = followedLogins.contains(login)
        let isPending = pendingFollow.contains(login)
        Button {
            guard !isPending else { return }
            pendingFollow.insert(login)
            Task {
                defer { pendingFollow.remove(login) }
                if isFollowed {
                    try? await APIClient.shared.unfollow(login: login)
                    followedLogins.remove(login)
                } else {
                    try? await APIClient.shared.follow(login: login)
                    followedLogins.insert(login)
                }
            }
        } label: {
            Group {
                if isPending {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isFollowed ? "Following" : "Follow")
                }
            }
            .font(.geist(13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isFollowed ? Color(.tertiarySystemFill) : Color("AccentColor"))
            .foregroundStyle(isFollowed ? Color(.label) : .white)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let result = try? await APIClient.shared.youMightKnow() {
            users = result
        }
        if let following = try? await APIClient.shared.followingList() {
            followedLogins = Set(following.map(\.login))
        }
    }
}
