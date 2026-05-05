import Foundation
import SwiftUI

@MainActor
final class AppUpdateChecker: ObservableObject {

    static let shared = AppUpdateChecker(
        fetcher: APIClientVersionFetcher(),
        defaults: .standard,
        currentVersion: { Config.appVersion },
        now: { Date() }
    )

    @Published private(set) var state: UpdateState = .unknown

    enum UpdateState: Equatable {
        case unknown
        case upToDate
        case updateAvailable(VersionInfo)
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
    /// 1-hour throttle (used by the push-tap re-check handler).
    func check(force: Bool = false) async {
        if !force,
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

    private func apply(manifest: AppVersionManifest) {
        guard
            let latest = SemVer(manifest.latestVersion),
            let current = SemVer(currentVersion())
        else {
            state = .unknown
            return
        }
        if !(current < latest) {
            state = .upToDate
            return
        }
        state = .updateAvailable(VersionInfo(
            latest: latest,
            latestRaw: manifest.latestVersion,
            releaseNotes: manifest.releaseNotes,
            storeUrl: manifest.storeUrl,
            appStoreId: manifest.appStoreId
        ))
    }
}
