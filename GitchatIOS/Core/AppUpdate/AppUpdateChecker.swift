import Foundation

/// Version-check orchestrator.
///
/// State machine for "is there a newer version available?" —
/// decoupled from the UI. `RootView` observes `state` and shows the
/// banner or full-screen cover accordingly; `APIClient` flips state
/// to `.forceUpdateRequired` on HTTP 426.
///
/// Source of truth is the BE manifest (`GET /app/version`, see
/// `docs/be-app-update-endpoint.md`). Until that ships we fall back
/// to Apple's public iTunes lookup API, which returns enough for the
/// soft-prompt path. The force-update gate stays dark until the BE
/// endpoint is live — we don't invent a `minimumSupportedVersion`.
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    @Published private(set) var state: UpdateState = .unknown

    enum UpdateState: Equatable {
        case unknown
        case upToDate
        case updateAvailable(VersionInfo)
        case forceUpdateRequired(VersionInfo)
    }

    struct VersionInfo: Equatable, Identifiable {
        let latestVersion: String
        let releaseNotes: String?
        let storeUrl: URL
        let appStoreId: String
        var id: String { appStoreId + "@" + latestVersion }
    }

    /// Short-circuits the banner when the user tapped "Later" recently.
    /// Keyed to the version they saw, so a newer release invalidates
    /// the snooze automatically.
    private enum SnoozeKey {
        static let untilDate = "appUpdate.snoozeUntil"
        static let forVersion = "appUpdate.snoozeForVersion"
    }

    private enum ThrottleKey {
        static let lastCheck = "appUpdate.lastCheckAt"
    }

    private let throttle: TimeInterval = 60 * 60
    private let snoozeWindow: TimeInterval = 60 * 60 * 24

    /// Cached VersionInfo from the last successful fetch — used by the
    /// 426 interceptor when the app gets gated mid-session and we
    /// don't have a fresh manifest to point at.
    private(set) var cachedInfo: VersionInfo?

    private init() {}

    // MARK: - Entry points

    /// Call on cold launch and on foreground transitions. Throttled to
    /// one hit/hour so scene phase churn doesn't spam either the BE or
    /// iTunes lookup.
    func check() async {
        if let last = UserDefaults.standard.object(forKey: ThrottleKey.lastCheck) as? Date,
           Date().timeIntervalSince(last) < throttle {
            return
        }
        await checkNow()
    }

    /// Bypass the throttle — used by the "app_update" push tap and by
    /// the 426 interceptor when it only has a status code.
    func checkNow() async {
        UserDefaults.standard.set(Date(), forKey: ThrottleKey.lastCheck)
        do {
            let info = try await fetchManifest()
            cachedInfo = info
            apply(info)
        } catch {
            // Offline / BE down / iTunes hiccup — leave state as-is.
            // The next foreground hit will retry.
        }
    }

    func snoozeCurrent() {
        guard case .updateAvailable(let info) = state else { return }
        let until = Date().addingTimeInterval(snoozeWindow)
        UserDefaults.standard.set(until, forKey: SnoozeKey.untilDate)
        UserDefaults.standard.set(info.latestVersion, forKey: SnoozeKey.forVersion)
        state = .upToDate
    }

    /// Called by `APIClient` on HTTP 426. Flips state to force-update
    /// using the best VersionInfo we have; if we've never fetched
    /// (rare — cold-launch race), refresh first.
    func forceFromGate() {
        if let info = cachedInfo {
            state = .forceUpdateRequired(info)
        }
        Task { [weak self] in
            await self?.checkNow()
            await MainActor.run {
                guard let self else { return }
                if let info = self.cachedInfo {
                    self.state = .forceUpdateRequired(info)
                }
            }
        }
    }

    // MARK: - Internals

    private func apply(_ info: VersionInfo) {
        guard let current = SemVer(Config.appVersion),
              let remote = SemVer(info.latestVersion) else {
            state = .upToDate
            return
        }
        if remote <= current {
            state = .upToDate
            return
        }
        if let until = UserDefaults.standard.object(forKey: SnoozeKey.untilDate) as? Date,
           let snoozedVersion = UserDefaults.standard.string(forKey: SnoozeKey.forVersion),
           snoozedVersion == info.latestVersion,
           Date() < until {
            state = .upToDate
            return
        }
        state = .updateAvailable(info)
    }

    // MARK: - Manifest fetch (iTunes lookup fallback)

    /// For now this hits Apple's public iTunes lookup API, which is
    /// good enough for the soft-prompt path. When BE ships
    /// `GET /app/version?platform=ios` (see docs), swap this for an
    /// `APIClient` call and carry through `minimumSupportedVersion` +
    /// `isForceUpdate` to populate the `.forceUpdateRequired` path.
    private func fetchManifest() async throws -> VersionInfo {
        let bundleId = Bundle.main.bundleIdentifier ?? "chat.git"
        let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleId)")!
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: req)
        let decoded = try JSONDecoder().decode(ITunesLookupResponse.self, from: data)
        guard let first = decoded.results.first,
              let storeUrl = URL(string: first.trackViewUrl) else {
            throw LookupError.notFound
        }
        return VersionInfo(
            latestVersion: first.version,
            releaseNotes: first.releaseNotes,
            storeUrl: storeUrl,
            appStoreId: String(first.trackId)
        )
    }

    private enum LookupError: Error { case notFound }

    private struct ITunesLookupResponse: Decodable {
        let results: [ITunesApp]
    }

    private struct ITunesApp: Decodable {
        let version: String
        let releaseNotes: String?
        let trackViewUrl: String
        let trackId: Int
    }
}

// MARK: - TestFlight detection

enum AppDistributionChannel {
    case appStore
    case testFlight
    case development

    static var current: AppDistributionChannel {
        #if targetEnvironment(simulator)
        return .development
        #else
        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return .development }
        if receiptURL.lastPathComponent == "sandboxReceipt" { return .testFlight }
        return .appStore
        #endif
    }
}
