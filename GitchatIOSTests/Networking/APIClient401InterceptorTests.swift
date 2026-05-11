import XCTest
@testable import Gitchat

@MainActor
final class APIClient401InterceptorTests: XCTestCase {

    private func makeStubClient() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        return APIClient(session: session)
    }

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        // Unique token per test so the production token-match guard in
        // `AuthStore.handle401(forToken:)` naturally isolates one test
        // from another: any intercept-dispatched Task that hasn't run
        // yet captured a stale token that won't match the next test's
        // freshly-primed token.
        AuthStore.shared._testPrimeAuth(token: "expired-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        AuthStore.shared._testClearAuth()
        try await super.tearDown()
    }

    func test_401OnAuthedRequest_triggersSignOut() async throws {
        StubURLProtocol.responseStatus = 401
        StubURLProtocol.responseBody = Data(#"{"error":"jwt expired"}"#.utf8)

        let client = makeStubClient()
        _ = try? await client.followingList()   // any authed GET

        // intercept dispatches a Task — wait for it to land on MainActor
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(
            AuthStore.shared.isAuthenticated,
            "401 on an authed request must clear the session"
        )
    }

    func test_handle401_staleToken_noOps() {
        // Production race: a request was sent under token A; user
        // re-auths to token B; the slow 401 response under A arrives
        // afterward. The stale 401 must NOT log the user out of the
        // fresh session.
        AuthStore.shared._testPrimeAuth(token: "fresh-token")
        AuthStore.shared.handle401(forToken: "stale-token")
        XCTAssertTrue(
            AuthStore.shared.isAuthenticated,
            "mismatched staleToken must NOT sign out — that's a stale 401 from before re-auth"
        )
    }

    func test_handle401_matchingToken_signsOut() {
        AuthStore.shared._testPrimeAuth(token: "current-token")
        AuthStore.shared.handle401(forToken: "current-token")
        XCTAssertFalse(
            AuthStore.shared.isAuthenticated,
            "matching staleToken means the live session's token is the one BE rejected — sign out"
        )
    }

    func test_handle401_nilToken_noOps() {
        // Defensive: a 401 from a path with no Authorization header at
        // all shouldn't sign anyone out. Belt-and-suspenders alongside
        // the requireAuth guard at the call site.
        AuthStore.shared._testPrimeAuth(token: "current-token")
        AuthStore.shared.handle401(forToken: nil)
        XCTAssertTrue(AuthStore.shared.isAuthenticated)
    }

    func test_200Response_keepsSessionAuthed() async throws {
        StubURLProtocol.responseStatus = 200
        StubURLProtocol.responseBody = Data(#"{"data":{"users":[]}}"#.utf8)

        let client = makeStubClient()
        _ = try? await client.followingList()

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(
            AuthStore.shared.isAuthenticated,
            "must not sign out on 2xx"
        )
    }

    func test_401OnUnauthedRequest_doesNotSignOut() async throws {
        // A 401 from a sign-in path / public endpoint must not nuke the
        // current session — that would tear the user out of the app
        // because of an unrelated public-endpoint failure.
        StubURLProtocol.responseStatus = 401
        StubURLProtocol.responseBody = Data(#"{"error":"unauthorized"}"#.utf8)

        let client = makeStubClient()
        _ = try? await client.trendingRepos()   // requireAuth: false

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(
            AuthStore.shared.isAuthenticated,
            "401 on a requireAuth:false call must NOT sign the user out"
        )
    }

    func test_uploadAttachment401_triggersSignOut() async throws {
        StubURLProtocol.responseStatus = 401
        StubURLProtocol.responseBody = Data(#"{"error":"jwt expired"}"#.utf8)

        let client = makeStubClient()
        _ = try? await client.uploadAttachment(
            data: Data([0x00]),
            filename: "x.bin",
            mimeType: "application/octet-stream",
            conversationId: "c1"
        )

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(
            AuthStore.shared.isAuthenticated,
            "401 on upload (always authed) must clear the session"
        )
    }

    func test_handle401_isIdempotent() async throws {
        // Multiple in-flight requests can all 401 at once when the BE
        // expires the token. Only the first should fire the toast/clear
        // path; the rest must no-op via the isAuthenticated guard.
        StubURLProtocol.responseStatus = 401
        StubURLProtocol.responseBody = Data(#"{"error":"jwt expired"}"#.utf8)

        let client = makeStubClient()
        async let a: Void = { _ = try? await client.followingList() }()
        async let b: Void = { _ = try? await client.followingList() }()
        async let c: Void = { _ = try? await client.followingList() }()
        _ = await (a, b, c)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(AuthStore.shared.isAuthenticated)
        // No assertion on toast count — ToastCenter doesn't expose it —
        // but the guard in handle401() ensures signOut() only mutates
        // the keychain once. Rerunning signOut on an already-cleared
        // store is benign (SecItemDelete on a missing key is OK).
    }
}
