import XCTest
@testable import Gitchat

@MainActor
final class AppUpdateCheckerSnoozeTests: XCTestCase {

    private final class MutableFetcher: VersionFetcher {
        var manifest: AppVersionManifest
        init(latest: String) {
            self.manifest = AppVersionManifest(
                latestVersion: latest,
                releaseNotes: nil,
                releasedAt: nil,
                storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
                appStoreId: "1",
                minimumSupportedVersion: "1.0.0",
                isForceUpdate: false
            )
        }
        func fetch() async throws -> AppVersionManifest { manifest }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppUpdateCheckerSnoozeTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_snooze_immediately_flips_state_to_upToDate() async {
        let checker = AppUpdateChecker(
            fetcher: MutableFetcher(latest: "2.0.0"),
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { Date() }
        )
        await checker.check()
        if case .updateAvailable = checker.state { /* ok */ } else {
            return XCTFail("setup: expected updateAvailable")
        }
        checker.snooze()
        XCTAssertEqual(checker.state, .upToDate, "snooze must hide banner immediately")
    }

    func test_snooze_persists_across_recheck_within_24h() async {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let checker = AppUpdateChecker(
            fetcher: MutableFetcher(latest: "2.0.0"),
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        checker.snooze()
        clock = clock.addingTimeInterval(2 * 60 * 60)        // 2h later
        await checker.check(force: true)                      // bypass throttle
        XCTAssertEqual(checker.state, .upToDate, "still inside 24h snooze; banner should stay hidden")
    }

    func test_snooze_invalidated_when_version_bumps() async {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let fetcher = MutableFetcher(latest: "2.0.0")
        let checker = AppUpdateChecker(
            fetcher: fetcher,
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        checker.snooze()
        // BE bumps version while we're still inside the 24h window.
        clock = clock.addingTimeInterval(60 * 60)
        fetcher.manifest = AppVersionManifest(
            latestVersion: "2.1.0",
            releaseNotes: nil,
            releasedAt: nil,
            storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
            appStoreId: "1",
            minimumSupportedVersion: "1.0.0",
            isForceUpdate: false
        )
        await checker.check(force: true)
        guard case .updateAvailable(let info) = checker.state else {
            return XCTFail("expected banner to re-appear for newer version")
        }
        XCTAssertEqual(info.latestRaw, "2.1.0")
    }

    func test_snooze_expires_after_24h() async {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let checker = AppUpdateChecker(
            fetcher: MutableFetcher(latest: "2.0.0"),
            defaults: makeDefaults(),
            currentVersion: { "1.0.0" },
            now: { clock }
        )
        await checker.check()
        checker.snooze()
        clock = clock.addingTimeInterval(24 * 60 * 60 + 1)   // just past 24h
        await checker.check(force: true)
        if case .updateAvailable = checker.state { /* ok */ } else {
            XCTFail("snooze should have expired")
        }
    }
}
