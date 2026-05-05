import Foundation
import SwiftUI

@MainActor
final class AppUpdateChecker: ObservableObject {

    static var shared: AppUpdateChecker {
        _testOverride ?? _shared
    }

    private static let _shared = AppUpdateChecker(
        fetcher: APIClientVersionFetcher(),
        defaults: .standard,
        currentVersion: { Config.appVersion },
        now: { Date() }
    )

    #if DEBUG
    nonisolated(unsafe) static var _testOverride: AppUpdateChecker?
    #else
    static var _testOverride: AppUpdateChecker? { nil }
    #endif

    @Published private(set) var state: UpdateState = .unknown

    enum UpdateState: Equatable {
        case unknown
        case upToDate
        case updateAvailable(VersionInfo)
        case forceUpdateRequired(VersionInfo)
    }

    struct VersionInfo: Equatable {
        let latest: SemVer
        let latestRaw: String
        let releaseNotes: String?
        let storeUrl: URL
        let appStoreId: String
    }

    private let fetcher: VersionFetcher
    private let defaults: UserDefaults
    private let currentVersion: () -> String
    private let now: () -> Date

    private static let kLastChecked = "appUpdate.lastCheckedAt"
    private static let throttleInterval: TimeInterval = 60 * 60   // 1 hour

    static let kSnoozedUntil = "appUpdate.snoozedUntil"
    static let kSnoozedVersion = "appUpdate.snoozedVersion"
    private static let snoozeInterval: TimeInterval = 24 * 60 * 60   // 24 hours

    #if DEBUG
    private static var debugBypassEnabled: Bool {
        ProcessInfo.processInfo.environment["BYPASS_FORCE_UPDATE"] == "1"
    }
    #endif

    init(
        fetcher: VersionFetcher,
        defaults: UserDefaults,
        currentVersion: @escaping () -> String,
        now: @escaping () -> Date
    ) {
        self.fetcher = fetcher
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
    }

    /// Cold-launch and foreground entry point. `force == true` bypasses the
    /// 1-hour throttle (used by the push-tap re-check handler). The throttle
    /// is also bypassed automatically while `state == .forceUpdateRequired`
    /// so the user can recover from a BE flag-back without a cold launch —
    /// while walled, polling BE on every foreground is acceptable because
    /// the user is fully blocked from doing anything else.
    func check(force: Bool = false) async {
        let walled: Bool
        if case .forceUpdateRequired = state {
            walled = true
        } else {
            walled = false
        }
        if !force, !walled,
           let last = defaults.object(forKey: Self.kLastChecked) as? Date,
           now().timeIntervalSince(last) < Self.throttleInterval {
            return
        }
        defaults.set(now(), forKey: Self.kLastChecked)
        do {
            let manifest = try await fetcher.fetch()
            apply(manifest: manifest)
        } catch {
            NSLog("[AppUpdateChecker] fetch failed: \(error)")
        }
    }

    /// User tapped "Not now" on the banner. Hides the banner now and for
    /// the next 24h — unless BE bumps `latestVersion`, in which case the
    /// next `check()` re-surfaces the banner with the new version.
    func snooze() {
        guard case .updateAvailable(let info) = state else { return }
        defaults.set(now().addingTimeInterval(Self.snoozeInterval), forKey: Self.kSnoozedUntil)
        defaults.set(info.latestRaw, forKey: Self.kSnoozedVersion)
        state = .upToDate
    }

    /// Called by the APIClient 426 interceptor. Bare HTTP-status signal —
    /// flip to `.forceUpdateRequired` using whatever `VersionInfo` is
    /// cached (or `VersionInfo.fallback()` if none). Idempotent: if
    /// state is already `.forceUpdateRequired`, returns without doing
    /// work.
    ///
    /// We deliberately do NOT trigger a background `check(force: true)`
    /// here. Reasons: (1) the minimal `ForceUpdateView` does not display
    /// version data, so stale `VersionInfo` is invisible; (2) the
    /// hardcoded `Config.appStoreFallback` keeps the Update button
    /// working without a fresh manifest; (3) auto-refetching introduces
    /// a race where `apply(manifest:)` could downgrade state back to
    /// `.updateAvailable` if the BE is in an inconsistent state (426
    /// firing while the manifest still says no force). The next normal
    /// foreground `check()` will reconcile manifest state in due course.
    func handle426() async {
        if case .forceUpdateRequired = state { return }

        let cached: VersionInfo? = {
            switch state {
            case .updateAvailable(let info), .forceUpdateRequired(let info):
                return info
            default:
                return nil
            }
        }()

        state = .forceUpdateRequired(cached ?? .fallback())
    }

    private func apply(manifest: AppVersionManifest) {
        guard
            let latest = SemVer(manifest.latestVersion),
            let current = SemVer(currentVersion()),
            let minSupported = SemVer(manifest.minimumSupportedVersion)
        else {
            state = .unknown
            return
        }

        let info = VersionInfo(
            latest: latest,
            latestRaw: manifest.latestVersion,
            releaseNotes: manifest.releaseNotes,
            storeUrl: manifest.storeUrl,
            appStoreId: manifest.appStoreId
        )

        // Force triggers — bypass snooze entirely. Either the BE flipped
        // `isForceUpdate=true` (emergency override) or the user is below
        // the floor `minimumSupportedVersion`.
        if manifest.isForceUpdate || current < minSupported {
            #if DEBUG
            if Self.debugBypassEnabled {
                NSLog("[AppUpdateChecker] DEBUG bypass — would have forced update")
            } else {
                state = .forceUpdateRequired(info)
                return
            }
            #else
            state = .forceUpdateRequired(info)
            return
            #endif
        }

        // Soft path (PR #1 logic — unchanged)
        if !(current < latest) {
            state = .upToDate
            return
        }
        if let until = defaults.object(forKey: Self.kSnoozedUntil) as? Date,
           let snoozedVer = defaults.string(forKey: Self.kSnoozedVersion),
           until > now(),
           snoozedVer == manifest.latestVersion {
            state = .upToDate
            return
        }
        state = .updateAvailable(info)
    }
}

extension AppUpdateChecker.VersionInfo {
    /// Placeholder used by `handle426()` when an HTTP 426 fires before
    /// any successful manifest fetch — provides a working Update button
    /// via `Config.appStoreFallback`. The wall does not display the
    /// `latestRaw` value, so its placeholder is harmless.
    static func fallback() -> Self {
        .init(
            latest: SemVer("0.0.0")!,
            latestRaw: "—",
            releaseNotes: nil,
            storeUrl: Config.appStoreFallback.storeUrl,
            appStoreId: Config.appStoreFallback.appStoreId
        )
    }
}
