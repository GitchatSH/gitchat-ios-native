import XCTest
@testable import Gitchat

@MainActor
final class AppUpdateCheckerForceUpdateTests: XCTestCase {

    private struct StubFetcher: VersionFetcher {
        var manifest: AppVersionManifest
        func fetch() async throws -> AppVersionManifest { manifest }
    }

    private func makeManifest(
        latest: String = "1.5.0",
        minSupported: String = "1.0.0",
        force: Bool = false
    ) -> AppVersionManifest {
        AppVersionManifest(
            latestVersion: latest,
            releaseNotes: "Notes",
            releasedAt: nil,
            storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
            appStoreId: "1",
            minimumSupportedVersion: minSupported,
            isForceUpdate: force
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppUpdateCheckerForceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeChecker(
        manifest: AppVersionManifest,
        currentVersion: String
    ) -> AppUpdateChecker {
        AppUpdateChecker(
            fetcher: StubFetcher(manifest: manifest),
            defaults: makeDefaults(),
            currentVersion: { currentVersion },
            now: { Date() }
        )
    }

    // MARK: - Force triggers

    func test_isForceUpdateFlag_flipsToForceUpdateRequired() async {
        let checker = makeChecker(
            manifest: makeManifest(latest: "1.5.0", minSupported: "1.0.0", force: true),
            currentVersion: "1.5.0"   // up-to-date but force flag is set
        )
        await checker.check()
        guard case .forceUpdateRequired = checker.state else {
            return XCTFail("expected .forceUpdateRequired, got \(checker.state)")
        }
    }

    func test_belowMinimum_flipsToForceUpdateRequired() async {
        let checker = makeChecker(
            manifest: makeManifest(latest: "1.5.0", minSupported: "1.2.0"),
            currentVersion: "1.1.0"
        )
        await checker.check()
        guard case .forceUpdateRequired = checker.state else {
            return XCTFail("expected .forceUpdateRequired, got \(checker.state)")
        }
    }

    func test_equalToMinimum_notForced() async {
        let checker = makeChecker(
            manifest: makeManifest(latest: "1.2.0", minSupported: "1.2.0"),
            currentVersion: "1.2.0"
        )
        await checker.check()
        XCTAssertEqual(checker.state, .upToDate)
    }

    func test_forceTakesPrecedenceOverSnooze() async {
        let defaults = makeDefaults()
        let checker = AppUpdateChecker(
            fetcher: StubFetcher(manifest: makeManifest(latest: "2.0.0", minSupported: "2.0.0")),
            defaults: defaults,
            currentVersion: { "1.0.0" },
            now: { Date() }
        )
        // Pre-snooze the user against 2.0.0. Use the production constants
        // (not literal strings) so a future rename of the keys breaks this
        // test loudly instead of silently turning the snooze setup into a
        // no-op.
        defaults.set(Date().addingTimeInterval(60 * 60 * 24), forKey: AppUpdateChecker.kSnoozedUntil)
        defaults.set("2.0.0", forKey: AppUpdateChecker.kSnoozedVersion)
        await checker.check()
        // Force trigger (current < min) overrides snooze
        guard case .forceUpdateRequired = checker.state else {
            return XCTFail("force must override snooze, got \(checker.state)")
        }
    }

    func test_forceTakesPrecedenceOverUpdateAvailable() async {
        // latest > current AND force flag — must land on .forceUpdateRequired, not .updateAvailable
        let checker = makeChecker(
            manifest: makeManifest(latest: "2.0.0", minSupported: "1.0.0", force: true),
            currentVersion: "1.5.0"
        )
        await checker.check()
        guard case .forceUpdateRequired = checker.state else {
            return XCTFail("expected .forceUpdateRequired, got \(checker.state)")
        }
    }

    func test_recheckUnflipsForceState() async {
        // Start with force state, then flip flag back via a second fetch
        final class MutableFetcher: VersionFetcher {
            var manifest: AppVersionManifest
            init(_ m: AppVersionManifest) { self.manifest = m }
            func fetch() async throws -> AppVersionManifest { manifest }
        }
        let initialForce = AppVersionManifest(
            latestVersion: "1.5.0", releaseNotes: nil, releasedAt: nil,
            storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
            appStoreId: "1", minimumSupportedVersion: "1.0.0", isForceUpdate: true
        )
        let mutable = MutableFetcher(initialForce)
        let checker = AppUpdateChecker(
            fetcher: mutable,
            defaults: makeDefaults(),
            currentVersion: { "1.5.0" },
            now: { Date() }
        )
        await checker.check()
        guard case .forceUpdateRequired = checker.state else {
            return XCTFail("expected force after first check, got \(checker.state)")
        }

        // BE flips flag back
        mutable.manifest = AppVersionManifest(
            latestVersion: "1.5.0", releaseNotes: nil, releasedAt: nil,
            storeUrl: URL(string: "https://apps.apple.com/app/id1")!,
            appStoreId: "1", minimumSupportedVersion: "1.0.0", isForceUpdate: false
        )
        await checker.check(force: true)   // bypass throttle so the second check actually runs
        XCTAssertEqual(checker.state, .upToDate)
    }

    // MARK: - handle426()

    func test_handle426_noCachedInfo_usesFallback() async {
        let checker = makeChecker(
            manifest: makeManifest(),         // unused — handle426 doesn't await fetch
            currentVersion: "1.0.0"
        )
        XCTAssertEqual(checker.state, .unknown)
        await checker.handle426()
        guard case .forceUpdateRequired(let info) = checker.state else {
            return XCTFail("expected .forceUpdateRequired, got \(checker.state)")
        }
        // Fallback identity from Config.appStoreFallback
        XCTAssertEqual(info.appStoreId, Config.appStoreFallback.appStoreId)
        XCTAssertEqual(info.storeUrl, Config.appStoreFallback.storeUrl)
    }

    func test_handle426_withCachedInfo_reusesVersionInfo() async {
        // First make state .updateAvailable so we have cached VersionInfo
        let checker = makeChecker(
            manifest: makeManifest(latest: "1.5.0", minSupported: "1.0.0"),
            currentVersion: "1.0.0"
        )
        await checker.check()
        guard case .updateAvailable(let cached) = checker.state else {
            return XCTFail("expected .updateAvailable precondition, got \(checker.state)")
        }
        await checker.handle426()
        guard case .forceUpdateRequired(let info) = checker.state else {
            return XCTFail("expected .forceUpdateRequired, got \(checker.state)")
        }
        XCTAssertEqual(info.appStoreId, cached.appStoreId)
        XCTAssertEqual(info.latestRaw, cached.latestRaw)
    }

    func test_handle426_idempotent() async {
        let checker = makeChecker(
            manifest: makeManifest(force: true),
            currentVersion: "1.0.0"
        )
        await checker.check()
        guard case .forceUpdateRequired(let firstInfo) = checker.state else {
            return XCTFail("expected force precondition")
        }
        await checker.handle426()
        guard case .forceUpdateRequired(let secondInfo) = checker.state else {
            return XCTFail("expected still force after handle426")
        }
        // Idempotent — info should be unchanged (no re-render churn)
        XCTAssertEqual(firstInfo, secondInfo)
    }
}
