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
