import Foundation

protocol VersionFetcher {
    func fetch() async throws -> AppVersionManifest
}

struct APIClientVersionFetcher: VersionFetcher {
    func fetch() async throws -> AppVersionManifest {
        try await APIClient.shared.fetchAppVersionManifest()
    }
}
