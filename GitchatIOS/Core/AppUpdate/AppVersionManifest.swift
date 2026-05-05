import Foundation

struct AppVersionManifest: Decodable, Equatable {
    let latestVersion: String
    let releaseNotes: String?
    /// Raw ISO8601 string. Kept as `String` (not `Date`) in MVP to avoid
    /// touching the global `JSONDecoder` strategy used by other endpoints.
    let releasedAt: String?
    let storeUrl: URL
    let appStoreId: String
    /// Unused in MVP; parsed so PR #2 force-update logic doesn't have to
    /// touch the BE-contract layer.
    let minimumSupportedVersion: String
    /// Unused in MVP; parsed so PR #2 force-update logic doesn't have to
    /// touch the BE-contract layer.
    let isForceUpdate: Bool
}
