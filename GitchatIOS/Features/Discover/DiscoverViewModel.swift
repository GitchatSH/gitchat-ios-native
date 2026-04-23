import SwiftUI

@MainActor
final class DiscoverViewModel: ObservableObject {
    // Navigation
    @Published var subTab: DiscoverSubTab = .people
    @Published var query: String = ""

    // People
    @Published var mutuals: [FriendUser] = []
    @Published var peopleSearchResults: [FriendUser] = []
    @Published var peopleLoading = false
    @Published var peopleError: String?

    // Teams
    @Published var contributedRepos: [APIClient.ContributedRepo] = []
    @Published var teamsLoading = false
    @Published var teamsError: String?

    // Communities
    @Published var starredRepos: [APIClient.StarredRepo] = []
    @Published var communitiesLoading = false
    @Published var communitiesError: String?

    // Optimistic: repos the user just joined, removed from the list
    // immediately so the row doesn't flash while the socket catches up.
    @Published var pendingJoinedRepos: Set<String> = []

    private var searchTask: Task<Void, Never>?
    private let debounceNanos: UInt64 = 300_000_000

    // MARK: - Loading

    func loadAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadMutuals() }
            group.addTask { await self.loadContributed() }
            group.addTask { await self.loadStarred() }
        }
    }

    func loadMutuals() async {
        peopleLoading = true; defer { peopleLoading = false }
        do {
            mutuals = try await APIClient.shared.friendsMutual()
            peopleError = nil
        } catch {
            peopleError = error.localizedDescription
        }
    }

    func loadContributed() async {
        teamsLoading = true; defer { teamsLoading = false }
        do {
            contributedRepos = try await APIClient.shared.fetchContributedRepos()
            teamsError = nil
        } catch {
            teamsError = error.localizedDescription
        }
    }

    func loadStarred() async {
        communitiesLoading = true; defer { communitiesLoading = false }
        do {
            starredRepos = try await APIClient.shared.fetchStarredRepos()
            communitiesError = nil
        } catch {
            communitiesError = error.localizedDescription
        }
    }

    // MARK: - Search

    func onSubTabChange() {
        // Swapping sub-tabs — clear the in-flight people search. Teams /
        // Communities filter locally so there's nothing to cancel.
        searchTask?.cancel()
        peopleSearchResults = []
    }

    func scheduleSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !q.isEmpty else {
            peopleSearchResults = []
            return
        }
        // Only People hits an API — Teams/Communities filter locally.
        guard subTab == .people else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanos ?? 0)
            if Task.isCancelled { return }
            await self?.runPeopleSearch(q)
        }
    }

    private func runPeopleSearch(_ q: String) async {
        peopleLoading = true
        defer { peopleLoading = false }
        do {
            peopleSearchResults = try await APIClient.shared.searchUsersForDM(query: q)
            peopleError = nil
        } catch {
            peopleError = error.localizedDescription
            peopleSearchResults = []
        }
    }

    // MARK: - Derived lists

    /// Mutuals + API-search results, deduped by login, filtered by the
    /// current query when non-empty.
    func peopleRows() -> [FriendUser] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = mutuals + peopleSearchResults
        var seen = Set<String>()
        let deduped = base.filter { seen.insert($0.login).inserted }
        guard !q.isEmpty else { return deduped }
        return deduped.filter {
            $0.login.lowercased().contains(q) || ($0.name ?? "").lowercased().contains(q)
        }
    }

    /// Contributed repos minus the ones the user has already joined as
    /// a team conversation, and local-filtered by query.
    func teamRows(joinedTeamSlugs: Set<String>) -> [APIClient.ContributedRepo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return contributedRepos.filter { r in
            let slug = "\(r.owner)/\(r.name)".lowercased()
            guard !joinedTeamSlugs.contains(slug) else { return false }
            guard !pendingJoinedRepos.contains(slug) else { return false }
            guard !q.isEmpty else { return true }
            return slug.contains(q) || (r.description ?? "").lowercased().contains(q)
        }
    }

    func communityRows(joinedCommunitySlugs: Set<String>) -> [APIClient.StarredRepo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return starredRepos.filter { r in
            let slug = "\(r.owner)/\(r.name)".lowercased()
            guard !joinedCommunitySlugs.contains(slug) else { return false }
            guard !pendingJoinedRepos.contains(slug) else { return false }
            guard !q.isEmpty else { return true }
            return slug.contains(q) || (r.description ?? "").lowercased().contains(q)
        }
    }
}
