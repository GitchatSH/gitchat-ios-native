import XCTest
@testable import Gitchat

@MainActor
final class APIClient426InterceptorTests: XCTestCase {

    private func makeStubClient() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        return APIClient(session: session)
    }

    private func makeChecker() -> AppUpdateChecker {
        AppUpdateChecker(
            fetcher: NoopFetcher(),
            defaults: UserDefaults(suiteName: "APIClient426Tests-\(UUID().uuidString)")!,
            currentVersion: { "1.0.0" },
            now: { Date() }
        )
    }

    private struct NoopFetcher: VersionFetcher {
        func fetch() async throws -> AppVersionManifest {
            throw NSError(domain: "noop", code: 1)
        }
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        AppUpdateChecker._testOverride = makeChecker()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        AppUpdateChecker._testOverride = nil
        super.tearDown()
    }

    func test_426Response_triggersHandle426() async throws {
        StubURLProtocol.responseStatus = 426
        StubURLProtocol.responseBody = Data("{}".utf8)

        let client = makeStubClient()
        _ = try? await client.followingList()   // any non-/app/version GET

        // handle426 dispatches a Task — wait briefly for it to land
        try await Task.sleep(nanoseconds: 200_000_000)
        guard case .forceUpdateRequired = AppUpdateChecker.shared.state else {
            return XCTFail("expected .forceUpdateRequired after 426; got \(AppUpdateChecker.shared.state)")
        }
    }

    func test_200Response_doesNotTriggerHandle426() async throws {
        StubURLProtocol.responseStatus = 200
        StubURLProtocol.responseBody = Data(#"{"data":{"users":[]}}"#.utf8)

        let client = makeStubClient()
        _ = try? await client.followingList()

        try await Task.sleep(nanoseconds: 200_000_000)
        if case .forceUpdateRequired = AppUpdateChecker.shared.state {
            XCTFail("must not flip to force on 200")
        }
    }

    func test_appVersionEndpoint_skipsInterceptor() async throws {
        // Fire the 426 from the app/version endpoint itself — interceptor
        // must skip to avoid an infinite re-check loop.
        StubURLProtocol.responseStatus = 426
        StubURLProtocol.responseBody = Data("{}".utf8)

        let client = makeStubClient()
        _ = try? await client.fetchAppVersionManifest()

        try await Task.sleep(nanoseconds: 200_000_000)
        if case .forceUpdateRequired = AppUpdateChecker.shared.state {
            XCTFail("must not trigger handle426 from /app/version endpoint")
        }
    }

    func test_performUpload426_triggersHandle426() async throws {
        StubURLProtocol.responseStatus = 426
        StubURLProtocol.responseBody = Data("{}".utf8)

        let client = makeStubClient()
        _ = try? await client.uploadAttachment(
            data: Data([0x00]),
            filename: "x.bin",
            mimeType: "application/octet-stream",
            conversationId: "c1"
        )

        try await Task.sleep(nanoseconds: 200_000_000)
        guard case .forceUpdateRequired = AppUpdateChecker.shared.state else {
            return XCTFail("expected force after upload 426; got \(AppUpdateChecker.shared.state)")
        }
    }
}
