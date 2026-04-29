import Foundation

struct GitHubEventPayload: Decodable, Equatable {
    let eventType: String
    let title: String
    let url: String?
    let actor: String?
    let githubEventId: String?
}
