import XCTest
@testable import Gitchat

@MainActor
final class AppUpdateCheckerThrottleTests: XCTestCase {

    private final class CountingFetcher: VersionFetcher {
        var calls = 0
        var manifest: AppVersionManifest = .init(
            latestVersion: "2.0.0",
            releaseNotes: nil,
            releasedAt: nil,
            storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
            appStoreId: "1",
            minimumSupportedVersion: "1.0.0",
            isForceUpdate: false
        )
        func fetch() async throws -> AppVersionManifest { calls += 1; return manifest }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppUpdateCheckerThrottleTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_first_check_always_runs() async {
        let fetcher = CountingFetcher()
        let checker = AppUpdateChecker(
            fetcher: fetcher,
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        await checker.check()
        XCTAssertEqual(fetcher.calls, 1)
    }

    func test_second_check_within_one_hour_is_throttled() async {
        let fetcher = CountingFetcher()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let checker = AppUpdateChecker(
            fetcher: fetcher,
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        clock = clock.addingTimeInterval(30 * 60)  // 30 min later
        await checker.check()
        XCTAssertEqual(fetcher.calls, 1, "second call within 1h must be skipped")
    }

    func test_check_after_one_hour_runs_again() async {
        let fetcher = CountingFetcher()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let checker = AppUpdateChecker(
            fetcher: fetcher,
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        clock = clock.addingTimeInterval(60 * 60 + 1)  // just past 1h
        await checker.check()
        XCTAssertEqual(fetcher.calls, 2)
    }

    func test_force_bypasses_throttle() async {
        let fetcher = CountingFetcher()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let checker = AppUpdateChecker(
            fetcher: fetcher,
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        clock = clock.addingTimeInterval(30)  // 30s later
        await checker.check(force: true)
        XCTAssertEqual(fetcher.calls, 2, "force=true must ignore throttle")
    }
}
