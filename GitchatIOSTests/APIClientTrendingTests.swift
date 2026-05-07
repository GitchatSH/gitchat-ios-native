import XCTest
@testable import Gitchat

final class APIClientTrendingTests: XCTestCase {

    /// Build an APIClient that routes through StubURLProtocol — same
    /// pattern as `APIClientSendMessageTests`. The injected `URLSession`
    /// only intercepts the network layer; `requireAuth: true` paths still
    /// read `AuthStore.shared.accessToken`. The regression test below
    /// signs out explicitly to make that read return nil.
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
        {"data":[{"owner":"vercel","name":"next.js","description":"The React Framework","language":"TypeScript","stars":100000,"avatar_url":"https://x/a.png"}],"page":1,"hasMore":false}
        """#.utf8)

        let repos = try await makeStubClient().trendingRepos()
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos.first?.owner, "vercel")
        XCTAssertEqual(repos.first?.name, "next.js")
        XCTAssertEqual(repos.first?.fullName, "vercel/next.js")
    }

    func test_trendingPeople_decodes_response() async throws {
        StubURLProtocol.responseBody = Data(#"""
        {"data":[{"login":"tj","name":"TJ","avatar_url":"https://x/a.png"}],"page":1,"hasMore":false}
        """#.utf8)

        let people = try await makeStubClient().trendingPeople()
        XCTAssertEqual(people.first?.login, "tj")
        XCTAssertEqual(people.first?.name, "TJ")
    }

}
