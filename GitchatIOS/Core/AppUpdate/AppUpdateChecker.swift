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

    /// Cold-launch and foreground entry point. `force == true` is reserved
    /// for push-tap re-checks (Task 5 wires the throttle bypass).
    func check(force: Bool = false) async {
        do {
            let manifest = try await fetcher.fetch()
            apply(manifest: manifest)
        } catch {
            NSLog("[AppUpdateChecker] fetch failed: \(error)")
            // leave state unchanged on transient failure
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
