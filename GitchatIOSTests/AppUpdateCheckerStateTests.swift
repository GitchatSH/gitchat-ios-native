import XCTest
@testable import Gitchat

@MainActor
final class AppUpdateCheckerStateTests: XCTestCase {

    private struct StubFetcher: VersionFetcher {
        let result: Result<AppVersionManifest, Error>
        func fetch() async throws -> AppVersionManifest {
            switch result {
            case .success(let m): return m
            case .failure(let e): throw e
            }
        }
    }

    private func makeManifest(latest: String, force: Bool = false) -> AppVersionManifest {
        AppVersionManifest(
            latestVersion: latest,
            releaseNotes: "Notes",
            releasedAt: nil,
            storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
            appStoreId: "1",
            minimumSupportedVersion: "1.0.0",
            isForceUpdate: force
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppUpdateCheckerTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_latest_greater_than_current_emits_updateAvailable() async {
        let checker = AppUpdateChecker(
            fetcher: StubFetcher(result: .success(makeManifest(latest: "1.2.0"))),
            defaults: makeDefaults(),
            currentVersion: { "1.1.0" },
            now: { Date() }
        )
        await checker.check()
        guard case .updateAvailable(let info) = checker.state else {
            return XCTFail("expected .updateAvailable, got \(checker.state)")
        }
        XCTAssertEqual(info.latestRaw, "1.2.0")
        XCTAssertEqual(info.releaseNotes, "Notes")
        XCTAssertEqual(info.appStoreId, "1")
    }

    func test_latest_equal_to_current_emits_upToDate() async {
        let checker = AppUpdateChecker(
            fetcher: StubFetcher(result: .success(makeManifest(latest: "1.1.0"))),
            defaults: makeDefaults(),
            currentVersion: { "1.1.0" },
            now: { Date() }
        )
        await checker.check()
        XCTAssertEqual(checker.state, .upToDate)
    }

    func test_latest_less_than_current_emits_upToDate() async {
        let checker = AppUpdateChecker(
            fetcher: StubFetcher(result: .success(makeManifest(latest: "0.9.0"))),
            defaults: makeDefaults(),
            currentVersion: { "1.1.0" },
            now: { Date() }
        )
        await checker.check()
        XCTAssertEqual(checker.state, .upToDate)
    }

    func test_fetch_failure_leaves_state_unchanged() async {
        struct E: Error {}
        let checker = AppUpdateChecker(
            fetcher: StubFetcher(result: .failure(E())),
            defaults: makeDefaults(),
            currentVersion: { "1.1.0" },
            now: { Date() }
        )
        XCTAssertEqual(checker.state, .unknown)
        await checker.check()
        XCTAssertEqual(checker.state, .unknown)  // unchanged
    }

    func test_malformed_latestVersion_emits_unknown() async {
        let checker = AppUpdateChecker(
            fetcher: StubFetcher(result: .success(makeManifest(latest: "not-semver"))),
            defaults: makeDefaults(),
            currentVersion: { "1.1.0" },
            now: { Date() }
        )
        await checker.check()
        XCTAssertEqual(checker.state, .unknown)
    }
}
