import XCTest
@testable import Gitchat

final class APIClientTrendingTests: XCTestCase {

    /// Build an APIClient that routes through StubURLProtocol — same
    /// pattern as `APIClientSendMessageTests`. Using an injected client
    /// means the test does not depend on `AuthStore.shared`'s state, so
    /// `requireAuth: false` (the behaviour we want to verify) is exercised
    /// regardless of whatever token a prior test or simulator state left
    /// in the keychain.
    private func makeStubClient() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return APIClient(session: URLSession(configuration: cfg))
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func test_trendingRepos_decodes_response() async throws {
        StubURLProtocol.responseBody = Data(#"""
        {"repos":[{"owner":"vercel","name":"next.js","description":"The React Framework","language":"TypeScript","stars":100000,"avatar_url":"https://x/a.png"}]}
        """#.utf8)

        let repos = try await makeStubClient().trendingRepos()
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos.first?.owner, "vercel")
        XCTAssertEqual(repos.first?.name, "next.js")
        XCTAssertEqual(repos.first?.fullName, "vercel/next.js")
    }

    func test_trendingPeople_decodes_response() async throws {
        StubURLProtocol.responseBody = Data(#"""
        {"users":[{"login":"tj","name":"TJ","avatar_url":"https://x/a.png"}]}
        """#.utf8)

        let people = try await makeStubClient().trendingPeople()
        XCTAssertEqual(people.first?.login, "tj")
        XCTAssertEqual(people.first?.name, "TJ")
    }

    /// Guards against a regression where someone removes `requireAuth: false`.
    func test_trendingRepos_does_not_require_token() async throws {
        await AuthStore.shared.signOut()
        StubURLProtocol.responseBody = Data(#"{"repos":[]}"#.utf8)
        do {
            _ = try await makeStubClient().trendingRepos()
        } catch APIError.notAuthenticated {
            XCTFail("Trending must be callable without a token (requireAuth must be false)")
        } catch {
            // Any other error is fine — only `.notAuthenticated` is the regression we guard.
        }
    }
}
