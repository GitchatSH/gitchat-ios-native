import SwiftUI

struct DiscoverTeamsList: View {
    @ObservedObject var vm: DiscoverViewModel
    @ObservedObject var convosVM: ConversationsViewModel
    @State private var joining: Set<String> = []

    private var joinedSlugs: Set<String> {
        // Teams joined show up in the main conversations list as
        // `type == "team"`. Match by repo_full_name, lowercased.
        Set(convosVM.conversations
            .filter { $0.type == "team" }
            .compactMap { $0.repo_full_name?.lowercased() }
        )
    }

    var body: some View {
        let rows = vm.teamRows(joinedTeamSlugs: joinedSlugs)
        Group {
            if vm.teamsLoading && rows.isEmpty {
                SkeletonList(count: 8, avatarSize: 40)
            } else if let err = vm.teamsError, rows.isEmpty {
                errorState(err)
            } else if rows.isEmpty {
                emptyState
            } else {
                List(rows) { repo in
                    DiscoverRepoRow(
                        title: repo.fullName,
                        subtitle: repo.description ?? flavor(for: repo),
                        avatarUrl: repo.avatarUrl,
                        isJoining: joining.contains(repo.fullName),
                        onJoin: { Task { await join(repo) } }
                    )
                    .listRowSeparator(.hidden)
                    #if targetEnvironment(macCatalyst)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    #endif
                    .hideMacScrollIndicators()
                }
                .listStyle(.plain)
                .macRowListContainer()
                .scrollIndicators(.hidden, axes: .vertical)
            }
        }
    }

    private func flavor(for repo: APIClient.ContributedRepo) -> String {
        if let commits = repo.commitCount, commits > 0 {
            return "\(commits) commit\(commits == 1 ? "" : "s")"
        }
        return "Contributor team"
    }

    private func join(_ repo: APIClient.ContributedRepo) async {
        let slug = repo.fullName
        joining.insert(slug); defer { joining.remove(slug) }
        do {
            let convo = try await APIClient.shared.joinTeam(repoFullName: slug)
            vm.pendingJoinedRepos.insert(slug.lowercased())
            ToastCenter.shared.show(.success, "Joined \(slug)")
            await convosVM.load()
            AppRouter.shared.openConversation(id: convo.id)
        } catch {
            ToastCenter.shared.show(.warning, eligibilityMessage(for: error))
        }
    }

    private var emptyState: some View {
        let q = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return ContentUnavailableCompat(
                title: "No teams match \"\(q)\"",
                systemImage: "magnifyingglass",
                description: "Try a different repo name."
            )
        }
        if vm.contributedRepos.isEmpty {
            return ContentUnavailableCompat(
                title: "No contributed repos yet",
                systemImage: "arrow.triangle.branch",
                description: "Contribute to repos on GitHub to join their teams."
            )
        }
        return ContentUnavailableCompat(
            title: "All caught up",
            systemImage: "checkmark.circle",
            description: "You've joined teams for all your contributed repos."
        )
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Couldn't load contributed repos").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Retry") { Task { await vm.loadContributed() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DiscoverCommunitiesList: View {
    @ObservedObject var vm: DiscoverViewModel
    @ObservedObject var convosVM: ConversationsViewModel
    @State private var joining: Set<String> = []

    private var joinedSlugs: Set<String> {
        Set(convosVM.conversations
            .filter { $0.type == "community" }
            .compactMap { $0.repo_full_name?.lowercased() }
        )
    }

    var body: some View {
        let rows = vm.communityRows(joinedCommunitySlugs: joinedSlugs)
        Group {
            if vm.communitiesLoading && rows.isEmpty {
                SkeletonList(count: 8, avatarSize: 40)
            } else if let err = vm.communitiesError, rows.isEmpty {
                errorState(err)
            } else if rows.isEmpty {
                emptyState
            } else {
                List(rows) { repo in
                    DiscoverRepoRow(
                        title: repo.fullName,
                        subtitle: repo.description ?? "Community",
                        avatarUrl: repo.avatar_url,
                        isJoining: joining.contains(repo.fullName),
                        onJoin: { Task { await join(repo) } }
                    )
                    .listRowSeparator(.hidden)
                    #if targetEnvironment(macCatalyst)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    #endif
                    .hideMacScrollIndicators()
                }
                .listStyle(.plain)
                .macRowListContainer()
                .scrollIndicators(.hidden, axes: .vertical)
            }
        }
    }

    private func join(_ repo: APIClient.StarredRepo) async {
        let slug = repo.fullName
        joining.insert(slug); defer { joining.remove(slug) }
        do {
            let convo = try await APIClient.shared.joinCommunity(repoFullName: slug)
            vm.pendingJoinedRepos.insert(slug.lowercased())
            ToastCenter.shared.show(.success, "Joined \(slug)")
            await convosVM.load()
            AppRouter.shared.openConversation(id: convo.id)
        } catch {
            ToastCenter.shared.show(.warning, eligibilityMessage(for: error))
        }
    }

    private var emptyState: some View {
        let q = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return ContentUnavailableCompat(
                title: "No communities match \"\(q)\"",
                systemImage: "magnifyingglass",
                description: "Try a different repo name."
            )
        }
        if vm.starredRepos.isEmpty {
            return ContentUnavailableCompat(
                title: "No starred repos yet",
                systemImage: "star",
                description: "Star repos on GitHub to discover their communities."
            )
        }
        return ContentUnavailableCompat(
            title: "All caught up",
            systemImage: "checkmark.circle",
            description: "You've joined communities for all your starred repos."
        )
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Couldn't load starred repos").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Retry") { Task { await vm.loadStarred() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Reusable repo row for Teams + Communities — same shape, different copy.
private struct DiscoverRepoRow: View {
    let title: String
    let subtitle: String
    let avatarUrl: String?
    let isJoining: Bool
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RepoAvatar(url: avatarUrl, size: macRowAvatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(macRowTitleFont).lineLimit(1)
                Text(subtitle).font(macRowSubtitleFont).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: onJoin) {
                if isJoining {
                    ProgressView().controlSize(.small).frame(width: 60, height: 28)
                } else {
                    Text("Join")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isJoining)
        }
        #if targetEnvironment(macCatalyst)
        .padding(.horizontal, macRowHorizontalPadding)
        .padding(.vertical, macRowVerticalPadding)
        #else
        .padding(.vertical, 4)
        #endif
    }
}

private struct RepoAvatar: View {
    let url: String?
    let size: CGFloat
    var body: some View {
        AvatarView(url: url, size: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Pull a friendly eligibility message from a BE error — typically the
/// error body is `{ error: { message } }`.
private func eligibilityMessage(for error: Error) -> String {
    let raw = error.localizedDescription.lowercased()
    if raw.contains("contrib") {
        return "You need to have contributed to this repo to join its team."
    }
    if raw.contains("star") {
        return "Star this repo on GitHub first to join the community."
    }
    if raw.contains("already") {
        return "You've already joined this one."
    }
    return "Couldn't join — \(error.localizedDescription)"
}
