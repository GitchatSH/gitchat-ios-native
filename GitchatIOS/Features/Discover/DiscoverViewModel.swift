import SwiftUI

protocol DiscoverDataSource {
    func trendingRepos() async throws -> [APIClient.TrendingRepo]
    func trendingPeople() async throws -> [APIClient.TrendingUser]
    func friendsMutual() async throws -> [FriendUser]
    func fetchStarredRepos() async throws -> [APIClient.StarredRepo]
    func fetchContributedRepos() async throws -> [APIClient.ContributedRepo]
}

extension APIClient: DiscoverDataSource {}

@MainActor
final class DiscoverViewModel: ObservableObject {
    // Navigation
    @Published var subTab: DiscoverSubTab = .people
    @Published var query: String = ""

    // People (authed)
    @Published var mutuals: [FriendUser] = []
    @Published var peopleSearchResults: [FriendUser] = []
    @Published var peopleLoading = false
    @Published var peopleError: String?

    // Teams (authed)
    @Published var contributedRepos: [APIClient.ContributedRepo] = []
    @Published var teamsLoading = false
    @Published var teamsError: String?

    // Communities (authed)
    @Published var starredRepos: [APIClient.StarredRepo] = []
    @Published var communitiesLoading = false
    @Published var communitiesError: String?

    // Trending (guest)
    @Published var trendingRepos: [APIClient.TrendingRepo] = []
    @Published var trendingPeople: [APIClient.TrendingUser] = []
    @Published var trendingLoading = false
    @Published var trendingError: String?

    @Published var pendingJoinedRepos: Set<String> = []

    private var searchTask: Task<Void, Never>?
    private let debounceNanos: UInt64 = 300_000_000
    private let api: DiscoverDataSource
    private let isAuthenticated: @MainActor () -> Bool

    init(api: DiscoverDataSource = APIClient.shared,
         isAuthenticated: @escaping @MainActor () -> Bool = { AuthStore.shared.isAuthenticated }) {
        self.api = api
        self.isAuthenticated = isAuthenticated
    }

    // MARK: - Loading

    func loadAll() async {
        if isAuthenticated() {
            await loadAllAuthed()
        } else {
            await loadAllGuest()
        }
    }

    private func loadAllAuthed() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadMutuals() }
            group.addTask { await self.loadContributed() }
            group.addTask { await self.loadStarred() }
        }
    }

    private func loadAllGuest() async {
        trendingLoading = true; defer { trendingLoading = false }
        trendingError = nil
        async let repos = safeTrendingRepos()
        async let people = safeTrendingPeople()
        let (r, p) = await (repos, people)
        trendingRepos = r
        trendingPeople = p
    }

    private func safeTrendingRepos() async -> [APIClient.TrendingRepo] {
        do {
            let r = try await api.trendingRepos()
            return r
        } catch {
            if trendingError == nil {
                trendingError = error.localizedDescription
            }
            return []
        }
    }

    private func safeTrendingPeople() async -> [APIClient.TrendingUser] {
        do {
            let r = try await api.trendingPeople()
            return r
        } catch {
            if trendingError == nil {
                trendingError = error.localizedDescription
            }
            return []
        }
    }

    func loadMutuals() async {
        peopleLoading = true; defer { peopleLoading = false }
        do {
            mutuals = try await api.friendsMutual()
            peopleError = nil
        } catch {
            peopleError = error.localizedDescription
        }
    }

    func loadContributed() async {
        teamsLoading = true; defer { teamsLoading = false }
        do {
            contributedRepos = try await api.fetchContributedRepos()
            teamsError = nil
        } catch {
            teamsError = error.localizedDescription
        }
    }

    func loadStarred() async {
        communitiesLoading = true; defer { communitiesLoading = false }
        do {
            starredRepos = try await api.fetchStarredRepos()
            communitiesError = nil
        } catch {
            communitiesError = error.localizedDescription
        }
    }

    // MARK: - Search (unchanged from authed flow — guest search is handled in UserSearchView, not here)

    func onSubTabChange() {
        searchTask?.cancel()
        peopleSearchResults = []
    }

    func scheduleSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !q.isEmpty else { peopleSearchResults = []; return }
        guard subTab == .people else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanos ?? 0)
            if Task.isCancelled { return }
            await self?.runPeopleSearch(q)
        }
    }

    private func runPeopleSearch(_ q: String) async {
        peopleLoading = true; defer { peopleLoading = false }
        do {
            peopleSearchResults = try await APIClient.shared.searchUsersForDM(query: q)
            peopleError = nil
        } catch {
            peopleError = error.localizedDescription
            peopleSearchResults = []
        }
    }

    // MARK: - Derived lists (unchanged for authed flow)

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
