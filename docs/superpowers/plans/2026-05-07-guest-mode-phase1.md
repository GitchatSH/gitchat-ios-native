# Guest Mode (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship browse-first launch (no token → 2-tab `GuestTabView` with trending Discover + user search) and a single `SignInPromptSheet` that gates wave/follow/post/react/invite-accept behind GitHub OAuth. Sign in with Apple stays in this PR.

**Architecture:** `RootView` becomes 3-way (`MainTabView` if authed, `GuestTabView` otherwise; `SignInView` is no longer a root, only a `.fullScreenCover` from guest entry points). `DiscoverViewModel` branches on `AuthStore.shared.isAuthenticated` between personalised loaders and unauth `/trending/*` loaders. New `SignInPromptSheet(reason:)` is the universal sign-in interception surface.

**Spec:** `docs/superpowers/specs/2026-05-07-guest-mode-and-phase-out-siwa-design.md`

**Tech Stack:** SwiftUI, iOS 16+, XcodeGen, XCTest, XCUITest, `StubURLProtocol`, `MockAPIClient`.

---

## File Structure

**Create:**
- `GitchatIOS/Features/Auth/SignInPromptSheet.swift` — `SignInReason` enum + sheet view.
- `GitchatIOS/Features/Search/UserSearchView.swift` — search-by-login screen for guests.
- `GitchatIOS/App/GuestTabView.swift` — guest shell with Discover + Search tabs and Sign-in toolbar.
- `GitchatIOSTests/SignInReasonTests.swift` — enum title coverage.
- `GitchatIOSTests/DiscoverViewModelGuestTests.swift` — guest-branch loader test.
- `GitchatIOSTests/APIClientTrendingTests.swift` — trending endpoint shape + no-auth header.
- `GitchatIOSUITests/GuestModeTests.swift` — cold-launch + locked-action UI flow.

**Modify:**
- `GitchatIOS/Core/Networking/APIClient.swift` — add `trendingRepos()`, `trendingPeople()`, `TrendingRepo`, `TrendingUser`.
- `GitchatIOS/Core/Networking/APIClient+Invite.swift` — add `requireAuth: false` to `previewInvite`.
- `GitchatIOS/Core/Networking/AuthStore.swift` — add `-uiTestUnauthed` launch-arg short-circuit so UI tests can force guest state.
- `GitchatIOS/Features/Discover/DiscoverViewModel.swift` — branch `loadAll()`, add trending lists.
- `GitchatIOS/Features/Discover/DiscoverView.swift` — drop Communities sub-tab when guest; switch labels.
- `GitchatIOS/Features/Discover/DiscoverSubTab.swift` — add `allCases(forGuest:)` helper.
- `GitchatIOS/App/RootView.swift` — 3-way route, propagate sign-out → `GuestTabView`.
- `GitchatIOS/Features/Profile/ProfileView.swift` — guard wave + follow with `SignInPromptSheet`.
- `GitchatIOS/Features/Conversations/InvitePreviewSheet.swift` — guard Join with `SignInPromptSheet`.

> All new Swift sources must show up in `project.pbxproj` after `xcodegen generate`. CLAUDE.md mandates a `grep -c "<NewFile>.swift" GitchatIOS.xcodeproj/project.pbxproj` check after every regen — do not skip.

---

### Task 1: `APIClient` trending endpoints (TDD)

**Files:**
- Modify: `GitchatIOS/Core/Networking/APIClient.swift` (append near `// MARK: - App version` block)
- Test: `GitchatIOSTests/APIClientTrendingTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

Create `GitchatIOSTests/APIClientTrendingTests.swift`:

```swift
import XCTest
@testable import Gitchat

@MainActor
final class APIClientTrendingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        super.tearDown()
    }

    func test_trendingRepos_decodes_response_and_omits_bearer() async throws {
        let body = """
        {"repos":[{"owner":"vercel","name":"next.js","description":"d","language":"TS","stars":100000,"avatar_url":"https://x/a.png"}]}
        """
        StubURLProtocol.stub(matchingPathSuffix: "/trending/repos",
                             status: 200,
                             body: Data(body.utf8))
        let repos = try await APIClient.shared.trendingRepos()
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos.first?.owner, "vercel")
        XCTAssertEqual(repos.first?.name, "next.js")
        let req = StubURLProtocol.lastRequest!
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"),
                     "Trending endpoints must not send a Bearer token")
    }

    func test_trendingPeople_decodes_response_and_omits_bearer() async throws {
        let body = """
        {"users":[{"login":"tj","name":"TJ","avatar_url":"https://x/a.png"}]}
        """
        StubURLProtocol.stub(matchingPathSuffix: "/trending/people",
                             status: 200,
                             body: Data(body.utf8))
        let people = try await APIClient.shared.trendingPeople()
        XCTAssertEqual(people.first?.login, "tj")
        XCTAssertNil(StubURLProtocol.lastRequest!
            .value(forHTTPHeaderField: "Authorization"))
    }
}
```

- [ ] **Step 2: Run tests and confirm failure**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/APIClientTrendingTests
```
Expected: compile failure — `trendingRepos`/`trendingPeople` undefined.

- [ ] **Step 3: Add types + endpoints**

Append to `APIClient.swift` just above `// MARK: - App version`:

```swift
    // MARK: - Trending (public, no auth)

    struct TrendingRepo: Decodable, Identifiable, Hashable {
        let owner: String
        let name: String
        let description: String?
        let language: String?
        let stars: Int?
        let avatar_url: String?
        var id: String { "\(owner)/\(name)" }
        var fullName: String { "\(owner)/\(name)" }
    }

    struct TrendingUser: Decodable, Identifiable, Hashable {
        let login: String
        let name: String?
        let avatar_url: String?
        var id: String { login }
    }

    /// `GET /trending/repos`. Public — no Authorization header.
    func trendingRepos() async throws -> [TrendingRepo] {
        struct Resp: Decodable { let repos: [TrendingRepo] }
        let r: Resp = try await request(
            "trending/repos",
            requireAuth: false
        )
        return r.repos
    }

    /// `GET /trending/people`. Public — no Authorization header.
    func trendingPeople() async throws -> [TrendingUser] {
        struct Resp: Decodable { let users: [TrendingUser] }
        let r: Resp = try await request(
            "trending/people",
            requireAuth: false
        )
        return r.users
    }
```

- [ ] **Step 4: Regenerate project + rerun tests**

```bash
xcodegen generate
grep -c "APIClientTrendingTests.swift" GitchatIOS.xcodeproj/project.pbxproj
```
Expected: `>= 1`. If `0`, the file is not in the project — investigate before continuing.

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSTests/APIClientTrendingTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Core/Networking/APIClient.swift GitchatIOSTests/APIClientTrendingTests.swift GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(api): add /trending/repos + /trending/people unauth clients"
```

---

### Task 2: `previewInvite` requireAuth fix

**Files:**
- Modify: `GitchatIOS/Core/Networking/APIClient+Invite.swift:96-98`
- Test: `GitchatIOSTests/APIClientTrendingTests.swift` (extend, since it sets up StubURLProtocol)

- [ ] **Step 1: Add the failing test**

Append to `APIClientTrendingTests.swift`:

```swift
    func test_previewInvite_omits_bearer_for_guest() async throws {
        let body = """
        {"code":"abc","group_name":"g","conversation_id":"c"}
        """
        StubURLProtocol.stub(matchingPathSuffix: "/messages/conversations/join/abc",
                             status: 200,
                             body: Data(body.utf8))
        _ = try await APIClient.shared.previewInvite(code: "abc")
        XCTAssertNil(StubURLProtocol.lastRequest!
            .value(forHTTPHeaderField: "Authorization"),
            "Preview is documented public — must not require a token")
    }
```

- [ ] **Step 2: Run, confirm failure**

```bash
xcodebuild test ... -only-testing:GitchatIOSTests/APIClientTrendingTests/test_previewInvite_omits_bearer_for_guest
```
Expected: FAIL — without `requireAuth: false`, the call attaches the token (test fixture leaves a stale token from setup; if not, the call still attaches whatever AuthStore has). Verify the assertion fails.

- [ ] **Step 3: Edit `previewInvite`**

In `APIClient+Invite.swift`, change:

```swift
    func previewInvite(code: String) async throws -> InvitePreview {
        try await request("messages/conversations/join/\(code)")
    }
```
to:
```swift
    func previewInvite(code: String) async throws -> InvitePreview {
        try await request("messages/conversations/join/\(code)", requireAuth: false)
    }
```

Update the doc comment to drop the "may still require auth" hedging — BE confirms public.

- [ ] **Step 4: Run, confirm pass**

```bash
xcodebuild test ... -only-testing:GitchatIOSTests/APIClientTrendingTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Core/Networking/APIClient+Invite.swift GitchatIOSTests/APIClientTrendingTests.swift
git commit -m "fix(invite): preview is public — drop bearer for guest callers"
```

---

### Task 3: `SignInReason` + `SignInPromptSheet`

**Files:**
- Create: `GitchatIOS/Features/Auth/SignInPromptSheet.swift`
- Test: `GitchatIOSTests/SignInReasonTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `GitchatIOSTests/SignInReasonTests.swift`:

```swift
import XCTest
@testable import Gitchat

final class SignInReasonTests: XCTestCase {

    func test_titles_per_case() {
        XCTAssertEqual(SignInReason.wave(login: "ethan").title,
                       "Sign in to wave at @ethan")
        XCTAssertEqual(SignInReason.dm(login: "ethan").title,
                       "Sign in to message @ethan")
        XCTAssertEqual(SignInReason.follow(login: "ethan").title,
                       "Sign in to follow @ethan")
        XCTAssertEqual(SignInReason.post.title,
                       "Sign in to post")
        XCTAssertEqual(SignInReason.react.title,
                       "Sign in to react")
        XCTAssertEqual(SignInReason.invite.title,
                       "Sign in to join the group")
    }
}
```

- [ ] **Step 2: Run, confirm failure (compile error: SignInReason not defined)**

```bash
xcodebuild test ... -only-testing:GitchatIOSTests/SignInReasonTests
```
Expected: compile error.

- [ ] **Step 3: Create `SignInPromptSheet.swift`**

```swift
import SwiftUI

enum SignInReason: Equatable {
    case wave(login: String)
    case dm(login: String)
    case follow(login: String)
    case post
    case react
    case invite

    var title: String {
        switch self {
        case .wave(let login):   return "Sign in to wave at @\(login)"
        case .dm(let login):     return "Sign in to message @\(login)"
        case .follow(let login): return "Sign in to follow @\(login)"
        case .post:              return "Sign in to post"
        case .react:             return "Sign in to react"
        case .invite:            return "Sign in to join the group"
        }
    }
}

/// Bottom sheet shown when a guest taps a locked action. Wraps the
/// existing `SignInViewModel.startGithub()` flow so the sign-in path
/// is identical to the SignInView GitHub button.
struct SignInPromptSheet: View {
    let reason: SignInReason
    let onDismiss: () -> Void
    @StateObject private var vm = SignInViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.top, 24)
            Text(reason.title)
                .font(.geist(20, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("Gitchat uses your GitHub identity to send waves, message developers, and post in groups.")
                .font(.geist(13, weight: .regular))
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task {
                    await vm.startGithub()
                    if AuthStore.shared.isAuthenticated {
                        dismiss()
                        onDismiss()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if vm.isLoading {
                        ProgressView().tint(Color(.systemBackground))
                    } else {
                        Image("GitHubMark")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 17, height: 17)
                    }
                    Text("Sign in with GitHub")
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color(.label))
                .clipShape(Capsule())
                .foregroundStyle(Color(.systemBackground))
            }
            .padding(.horizontal, 24)
            .disabled(vm.isLoading)

            Button("Not now") { dismiss() }
                .font(.geist(13, weight: .regular))
                .foregroundStyle(Color(.secondaryLabel))
                .padding(.bottom, 24)

            if let err = vm.error {
                Text(err)
                    .font(.geist(12, weight: .regular))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .presentationDetents([.fraction(0.55)])
        .presentationDragIndicator(.visible)
    }
}
```

- [ ] **Step 4: Regenerate + run tests**

```bash
xcodegen generate
grep -c "SignInPromptSheet.swift" GitchatIOS.xcodeproj/project.pbxproj
grep -c "SignInReasonTests.swift" GitchatIOS.xcodeproj/project.pbxproj
xcodebuild test ... -only-testing:GitchatIOSTests/SignInReasonTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Auth/SignInPromptSheet.swift GitchatIOSTests/SignInReasonTests.swift GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(auth): add SignInReason enum + SignInPromptSheet"
```

---

### Task 4: `DiscoverViewModel` guest branch (TDD)

**Files:**
- Modify: `GitchatIOS/Features/Discover/DiscoverViewModel.swift`
- Test: `GitchatIOSTests/DiscoverViewModelGuestTests.swift`

The model currently calls `APIClient.shared.friendsMutual()`/`fetchStarredRepos()` directly. We add an `apiClient` injectable conforming to a small protocol to keep the test seam tight without rewriting the existing methods.

- [ ] **Step 1: Failing test**

Create `GitchatIOSTests/DiscoverViewModelGuestTests.swift`:

```swift
import XCTest
@testable import Gitchat

@MainActor
final class DiscoverViewModelGuestTests: XCTestCase {

    final class Fake: DiscoverDataSource {
        var trendingReposCalled = false
        var trendingPeopleCalled = false
        var mutualsCalled = false
        var starredCalled = false
        var contributedCalled = false

        func trendingRepos() async throws -> [APIClient.TrendingRepo] {
            trendingReposCalled = true
            return [.init(owner: "vercel", name: "next.js",
                          description: nil, language: nil,
                          stars: nil, avatar_url: nil)]
        }
        func trendingPeople() async throws -> [APIClient.TrendingUser] {
            trendingPeopleCalled = true
            return [.init(login: "tj", name: nil, avatar_url: nil)]
        }
        func friendsMutual() async throws -> [FriendUser] {
            mutualsCalled = true; return []
        }
        func fetchStarredRepos() async throws -> [APIClient.StarredRepo] {
            starredCalled = true; return []
        }
        func fetchContributedRepos() async throws -> [APIClient.ContributedRepo] {
            contributedCalled = true; return []
        }
    }

    func test_loadAll_guest_calls_only_trending_endpoints() async {
        let fake = Fake()
        let vm = DiscoverViewModel(api: fake, isAuthenticated: { false })
        await vm.loadAll()
        XCTAssertTrue(fake.trendingReposCalled)
        XCTAssertTrue(fake.trendingPeopleCalled)
        XCTAssertFalse(fake.mutualsCalled)
        XCTAssertFalse(fake.starredCalled)
        XCTAssertFalse(fake.contributedCalled)
        XCTAssertEqual(vm.trendingRepos.count, 1)
        XCTAssertEqual(vm.trendingPeople.count, 1)
    }

    func test_loadAll_authed_calls_personalised_endpoints() async {
        let fake = Fake()
        let vm = DiscoverViewModel(api: fake, isAuthenticated: { true })
        await vm.loadAll()
        XCTAssertTrue(fake.mutualsCalled)
        XCTAssertTrue(fake.starredCalled)
        XCTAssertTrue(fake.contributedCalled)
        XCTAssertFalse(fake.trendingReposCalled)
        XCTAssertFalse(fake.trendingPeopleCalled)
    }
}
```

- [ ] **Step 2: Run, confirm failure (compile errors: protocol/init missing)**

- [ ] **Step 3: Refactor `DiscoverViewModel`**

Replace `DiscoverViewModel.swift` with:

```swift
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
    private let isAuthenticated: () -> Bool

    init(api: DiscoverDataSource = APIClient.shared,
         isAuthenticated: @escaping () -> Bool = { AuthStore.shared.isAuthenticated }) {
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
        async let repos = safeTrendingRepos()
        async let people = safeTrendingPeople()
        let (r, p) = await (repos, people)
        trendingRepos = r
        trendingPeople = p
    }

    private func safeTrendingRepos() async -> [APIClient.TrendingRepo] {
        do {
            let r = try await api.trendingRepos()
            trendingError = nil
            return r
        } catch {
            trendingError = error.localizedDescription
            return []
        }
    }

    private func safeTrendingPeople() async -> [APIClient.TrendingUser] {
        do {
            let r = try await api.trendingPeople()
            return r
        } catch {
            trendingError = error.localizedDescription
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
```

- [ ] **Step 4: Verify tests pass and existing Discover tests still pass**

```bash
xcodegen generate
grep -c "DiscoverViewModelGuestTests.swift" GitchatIOS.xcodeproj/project.pbxproj
xcodebuild test ... -only-testing:GitchatIOSTests/DiscoverViewModelGuestTests
xcodebuild test ... -only-testing:GitchatIOSTests
```

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Discover/DiscoverViewModel.swift GitchatIOSTests/DiscoverViewModelGuestTests.swift GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(discover): branch loadAll on auth — trending feed for guests"
```

---

### Task 5: `DiscoverView` hides Communities for guest + Sign-in toolbar

**Files:**
- Modify: `GitchatIOS/Features/Discover/DiscoverSubTab.swift`
- Modify: `GitchatIOS/Features/Discover/DiscoverView.swift`

> The Sign-in toolbar button lives inside `DiscoverView`'s existing `NavigationStack` (gated on guest) rather than in `GuestTabView`. This avoids nested-NavigationStack pitfalls — `MainTabView` already mounts `DiscoverView` bare, so we keep that contract.

- [ ] **Step 1: Edit `DiscoverSubTab.swift`**

Replace the file contents with:

```swift
import Foundation

enum DiscoverSubTab: String, CaseIterable, Identifiable {
    case people, teams, communities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people:      return "People"
        case .teams:       return "Teams"
        case .communities: return "Communities"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .people:      return "Search people..."
        case .teams:       return "Search teams..."
        case .communities: return "Search communities..."
        }
    }

    /// Communities pulls personalised starred repos and is meaningless
    /// for unauthenticated browsing. Guests see only People/Teams.
    static func cases(forGuest: Bool) -> [DiscoverSubTab] {
        forGuest ? [.people, .teams] : DiscoverSubTab.allCases
    }
}
```

- [ ] **Step 2: Edit `DiscoverView.swift`**

After `@StateObject private var vm`, add:

```swift
    @EnvironmentObject private var auth: AuthStore
    @State private var showSignIn = false
```

In `body` Picker block, swap the `ForEach`:

```swift
                Picker("", selection: $vm.subTab) {
                    ForEach(DiscoverSubTab.cases(forGuest: !auth.isAuthenticated)) { t in
                        Text(t.title).tag(t)
                    }
                }
```

Replace `content` with:

```swift
    @ViewBuilder
    private var content: some View {
        if !auth.isAuthenticated {
            DiscoverGuestList(vm: vm)
        } else {
            switch vm.subTab {
            case .people:      DiscoverPeopleList(vm: vm)
            case .teams:       DiscoverTeamsList(vm: vm, convosVM: convos)
            case .communities: DiscoverCommunitiesList(vm: vm, convosVM: convos)
            }
        }
    }
```

Add a Sign-in toolbar item gated on guest. After `.refreshable { ... }` modifier, add:

```swift
            .toolbar {
                if !auth.isAuthenticated {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Sign in") { showSignIn = true }
                            .font(.geist(15, weight: .semibold))
                    }
                }
            }
            .fullScreenCover(isPresented: $showSignIn) {
                NavigationStack {
                    SignInView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Close") { showSignIn = false }
                            }
                        }
                }
            }
```

Add a minimal `DiscoverGuestList` view at the bottom of the same file (keeps the diff localised — no new file):

```swift
private struct DiscoverGuestList: View {
    @ObservedObject var vm: DiscoverViewModel
    var body: some View {
        Group {
            if vm.trendingLoading && vm.trendingRepos.isEmpty {
                ProgressView().padding(.top, 40)
            } else if let err = vm.trendingError, vm.trendingRepos.isEmpty {
                VStack(spacing: 8) {
                    Text("Couldn't load trending").font(.headline)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await vm.loadAll() } }
                        .buttonStyle(.borderedProminent)
                }.padding(.top, 40)
            } else {
                List {
                    Section("Trending repos") {
                        ForEach(vm.trendingRepos) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.fullName).font(.headline)
                                if let d = r.description, !d.isEmpty {
                                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                    Section("Trending people") {
                        ForEach(vm.trendingPeople) { u in
                            HStack {
                                AvatarView(url: u.avatar_url, size: 32, login: u.login)
                                VStack(alignment: .leading) {
                                    Text("@\(u.login)").font(.subheadline)
                                    if let n = u.name { Text(n).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/Features/Discover/DiscoverSubTab.swift GitchatIOS/Features/Discover/DiscoverView.swift
git commit -m "feat(discover): hide Communities sub-tab + render trending list for guests"
```

---

### Task 6: `UserSearchView`

**Files:**
- Create: `GitchatIOS/Features/Search/UserSearchView.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

/// Minimal search-by-login screen used by `GuestTabView`. Mounts a
/// `ProfileView` for the typed login on submit. ProfileView already
/// handles 404/5xx and renders public profiles via the unauthenticated
/// `GET /user/:username` endpoint.
struct UserSearchView: View {
    @State private var query: String = ""
    @State private var pushedLogin: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Find a developer")
                    .font(.geist(22, weight: .bold))
                    .padding(.top, 24)
                Text("Type a GitHub username to view their profile.")
                    .font(.geist(13, weight: .regular))
                    .foregroundStyle(Color(.secondaryLabel))
                TextField("e.g. tj", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24)
                    .onSubmit { submit() }
                Button("Open profile") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .navigationTitle("Search")
            .navigationDestination(item: $pushedLogin) { login in
                ProfileView(login: login)
            }
        }
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        pushedLogin = trimmed
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
grep -c "UserSearchView.swift" GitchatIOS.xcodeproj/project.pbxproj
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add GitchatIOS/Features/Search/UserSearchView.swift GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(search): add UserSearchView for guest mode"
```

---

### Task 7: `GuestTabView`

**Files:**
- Create: `GitchatIOS/App/GuestTabView.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct GuestTabView: View {
    var body: some View {
        TabView {
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "safari.fill") }

            UserSearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
    }
}
```

> Sign-in toolbar lives inside `DiscoverView` (Task 5) so we don't double-nest NavigationStacks. `GuestTabView` is intentionally minimal — its only job is to mount the two reachable surfaces.

- [ ] **Step 2: Build**

```bash
xcodegen generate
grep -c "GuestTabView.swift" GitchatIOS.xcodeproj/project.pbxproj
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

- [ ] **Step 3: Smoke check on a sim**

Boot a sim, install the build, launch with `-uiTestUnauthed` (added in Task 8). For now, this task is dark code — verification in Task 11.

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/App/GuestTabView.swift GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(app): add GuestTabView shell"
```

---

### Task 8: `RootView` 3-way routing + AuthStore test seam

**Files:**
- Modify: `GitchatIOS/Core/Networking/AuthStore.swift`
- Modify: `GitchatIOS/App/RootView.swift`

- [ ] **Step 1: Add the test seam to `AuthStore`**

In `AuthStore.swift` `private init()`, replace:

```swift
    private init() {
        self.accessToken = read(tokenKey)
        self.login = read(loginKey)
        self.isAuthenticated = accessToken != nil
        self.needsGithubLink = read(needsGithubKey) == "1"
        mirrorToSharedGroup()
    }
```
with:
```swift
    private init() {
        let forceUnauthed = ProcessInfo.processInfo.arguments.contains("-uiTestUnauthed")
        if forceUnauthed {
            self.accessToken = nil
            self.login = nil
            self.isAuthenticated = false
            self.needsGithubLink = false
        } else {
            self.accessToken = read(tokenKey)
            self.login = read(loginKey)
            self.isAuthenticated = accessToken != nil
            self.needsGithubLink = read(needsGithubKey) == "1"
        }
        mirrorToSharedGroup()
    }
```

- [ ] **Step 2: Replace `RootView.existingBody` branch**

In `RootView.swift`, replace:

```swift
            if auth.isAuthenticated {
                authedShell
                    .task { ... }
            } else {
                SignInView()
            }
```
with:
```swift
            if auth.isAuthenticated {
                authedShell
                    .task {
                        socket.connect()
                        if let login = auth.login { socket.subscribeUser(login: login) }
                        wireGlobalMessageBanner()
                        startHeartbeat()
                    }
            } else {
                GuestTabView()
            }
```

(`SignInView` is no longer reachable from RootView — only via `.fullScreenCover` from `GuestTabView` and `SignInPromptSheet`.)

- [ ] **Step 3: Build + run existing tests to make sure nothing regressed**

```bash
xcodegen generate
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
xcodebuild test ... -only-testing:GitchatIOSTests
```

- [ ] **Step 4: Manual sanity check on a sim**

```bash
xcrun simctl boot "iPhone 15" || true
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -derivedDataPath /tmp/Gitchat-DD build
xcrun simctl install booted /tmp/Gitchat-DD/Build/Products/Debug-iphonesimulator/Gitchat.app
xcrun simctl launch booted chat.git --args -uiTestUnauthed
```
Open the sim — expect to land on `GuestTabView` (Discover + Search tabs).

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Core/Networking/AuthStore.swift GitchatIOS/App/RootView.swift
git commit -m "feat(root): route unauth users to GuestTabView; add -uiTestUnauthed seam"
```

---

### Task 9: `ProfileView` locked actions

**Files:**
- Modify: `GitchatIOS/Features/Profile/ProfileView.swift`

- [ ] **Step 1: Add prompt-sheet state**

Near the other `@State` properties in `ProfileView`, add:

```swift
    @State private var promptReason: SignInReason?
```

- [ ] **Step 2: Gate `waveCTA` and follow button**

Replace `waveCTA(for:)` body's `Button { Task { await sendWave(to: login) } } label: ...` so the button action becomes:

```swift
        Button {
            if AuthStore.shared.isAuthenticated {
                Task { await sendWave(to: login) }
            } else {
                promptReason = .wave(login: login)
            }
        } label: {
            // ... existing label ...
        }
```

In the follow row (around line 107 / 140 — both call sites of `toggleFollow`), wrap the action:

```swift
                            Button {
                                if AuthStore.shared.isAuthenticated {
                                    Task { await toggleFollow(login: p.login) }
                                } else {
                                    promptReason = .follow(login: p.login)
                                }
                            } label: { ... }
```

- [ ] **Step 3: Mount the prompt sheet**

At the bottom of `body` (alongside the existing `.sheet(isPresented: $showUpgrade)` modifier), add:

```swift
        .sheet(item: $promptReason) { reason in
            SignInPromptSheet(reason: reason) {
                // After sign-in success, AuthStore flips and RootView
                // re-renders into MainTabView. Nothing else to do here —
                // context loss is documented v1 behaviour.
            }
        }
```

`SignInReason` is `Equatable` but not `Identifiable`. Wrap it locally:

```swift
extension SignInReason: Identifiable {
    public var id: String {
        switch self {
        case .wave(let l):   return "wave:\(l)"
        case .dm(let l):     return "dm:\(l)"
        case .follow(let l): return "follow:\(l)"
        case .post:          return "post"
        case .react:         return "react"
        case .invite:        return "invite"
        }
    }
}
```

> Place the extension in `SignInPromptSheet.swift` (next to the enum) so it's available to all callers, not just `ProfileView`.

- [ ] **Step 4: Build**

```bash
xcodegen generate
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Profile/ProfileView.swift GitchatIOS/Features/Auth/SignInPromptSheet.swift
git commit -m "feat(profile): gate wave + follow actions behind SignInPromptSheet for guests"
```

---

### Task 10: `InvitePreviewSheet` locked Join

**Files:**
- Modify: `GitchatIOS/Features/Conversations/InvitePreviewSheet.swift`

- [ ] **Step 1: Add prompt state**

Inside the view, add:

```swift
    @State private var promptReason: SignInReason?
```

- [ ] **Step 2: Gate the Join button (around line 71)**

Replace:

```swift
                    Task { await join() }
```
with:
```swift
                    if AuthStore.shared.isAuthenticated {
                        Task { await join() }
                    } else {
                        promptReason = .invite
                    }
```

- [ ] **Step 3: Mount the sheet**

Append to the view's body modifiers:

```swift
        .sheet(item: $promptReason) { reason in
            SignInPromptSheet(reason: reason) {}
        }
```

- [ ] **Step 4: Build + commit**

```bash
xcodegen generate
xcodebuild ... build
git add GitchatIOS/Features/Conversations/InvitePreviewSheet.swift
git commit -m "feat(invite): gate Join behind SignInPromptSheet for guests"
```

---

### Task 11: UI test — guest cold launch shows `GuestTabView`

**Files:**
- Create: `GitchatIOSUITests/GuestModeTests.swift`

- [ ] **Step 1: Write the test**

```swift
import XCTest

final class GuestModeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_cold_launch_unauthed_shows_GuestTabView() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTest", "-uiTestUnauthed"]
        app.launch()
        // Tab bar items
        XCTAssertTrue(app.tabBars.buttons["Discover"].waitForExistence(timeout: 5),
                      "Guest cold launch must show Discover tab")
        XCTAssertTrue(app.tabBars.buttons["Search"].exists,
                      "Guest cold launch must show Search tab")
        XCTAssertFalse(app.tabBars.buttons["Chats"].exists,
                       "Guest must not see Chats")
        // Sign-in button in trailing toolbar of Discover stack
        XCTAssertTrue(app.navigationBars.buttons["Sign in"].exists,
                      "Guest must have Sign in toolbar button")
    }
}
```

- [ ] **Step 2: Run**

```bash
xcodegen generate
grep -c "GuestModeTests.swift" GitchatIOS.xcodeproj/project.pbxproj
xcodebuild test \
  -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:GitchatIOSUITests/GuestModeTests/test_cold_launch_unauthed_shows_GuestTabView
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add GitchatIOSUITests/GuestModeTests.swift GitchatIOS.xcodeproj/project.pbxproj
git commit -m "test(uitest): GuestModeTests — cold-launch shell check"
```

---

### Task 12: UI test — locked-action sheet on profile

**Files:**
- Modify: `GitchatIOSUITests/GuestModeTests.swift`

- [ ] **Step 1: Add the test**

Append to `GuestModeTests`:

```swift
    func test_tap_wave_on_profile_shows_signin_prompt_sheet() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTest", "-uiTestUnauthed"]
        app.launch()

        app.tabBars.buttons["Search"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("tj")
        app.buttons["Open profile"].tap()

        // ProfileView fetches /user/tj. Wave CTA is "Wave" (label of the
        // primary button). Wait long enough for the unauthed profile read
        // to land before tapping.
        let waveButton = app.buttons["Wave"]
        XCTAssertTrue(waveButton.waitForExistence(timeout: 8),
                      "Profile load must surface Wave button")
        waveButton.tap()

        // Sheet title contains the typed login.
        XCTAssertTrue(app.staticTexts["Sign in to wave at @tj"]
                        .waitForExistence(timeout: 3),
                      "Tapping Wave on a profile while guest must show SignInPromptSheet")
        XCTAssertTrue(app.buttons["Sign in with GitHub"].exists)
        XCTAssertTrue(app.buttons["Not now"].exists)
    }
```

- [ ] **Step 2: Run**

```bash
xcodebuild test ... \
  -only-testing:GitchatIOSUITests/GuestModeTests/test_tap_wave_on_profile_shows_signin_prompt_sheet
```
Expected: PASS.

> If the test flakes on profile load (network), add a `XCTSkipIf` based on a cached fixture or a per-test API stub via launchEnvironment. For v1 we accept network-bound flake; the BE is reliable in CI.

- [ ] **Step 3: Commit**

```bash
git add GitchatIOSUITests/GuestModeTests.swift
git commit -m "test(uitest): tap Wave on profile shows SignInPromptSheet"
```

---

## Out-of-band tasks (no code, do not block PR)

- **App Store metadata copy** — draft new description first paragraph, keywords, promotional text emphasising "GitHub content client" + "browse without signing in". Apply via App Store Connect at PR-merge time (not in repo).
- **CLAUDE.md correction** — root iOS `CLAUDE.md` says "No XCTest target yet"; both targets exist. Append a sentence under Conventions clarifying the actual test workflow. Suggest the maintainer adopt this in a separate housekeeping commit (out of scope here).

## Verification before opening PR

- `xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 15' build` — zero warnings beyond pre-existing.
- `xcodebuild test ... -only-testing:GitchatIOSTests` — all unit tests pass.
- `xcodebuild test ... -only-testing:GitchatIOSUITests/GuestModeTests` — both new UI tests pass.
- Manual sim run with `-uiTestUnauthed`: Discover renders trending; Search → tj → wave → sheet.
- Manual sim run with a pre-populated keychain (real prior install): unchanged `MainTabView` cold launch.
- Sign out from Me tab → land on `GuestTabView`, not on a sign-in screen.

## Done definition

- All 12 tasks committed on `feat/guest-mode`.
- All tests pass locally.
- Spec's "Phase 1 PR" scope is fully covered; SIWA button still present (Phase 2 plan handles its removal).
- App Store description / metadata copy drafted (out of repo).
