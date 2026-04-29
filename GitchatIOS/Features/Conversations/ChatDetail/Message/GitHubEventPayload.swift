import Foundation
import SwiftUI

struct GitHubEventPayload: Decodable, Equatable {
    let eventType: String
    let title: String
    let url: String?
    let actor: String?
    let githubEventId: String?
}

struct GitHubEventStyle: Equatable {
    let icon: String     // SF Symbol
    let color: Color
    let verb: String     // e.g. "opened issue"

    static func from(eventType: String) -> GitHubEventStyle {
        switch eventType {
        case "issue_opened":
            return GitHubEventStyle(
                icon: "circle.dotted",
                color: .orange,
                verb: "opened issue"
            )
        default:
            return GitHubEventStyle(
                icon: "dot.radiowaves.left.and.right",
                color: .secondary,
                verb: humanize(eventType)
            )
        }
    }

    /// `pr_opened` → `opened pr`. `push` → `push` (no underscore = pass through).
    /// First component is treated as the object, second as the verb; they swap.
    static func humanize(_ eventType: String) -> String {
        let parts = eventType.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return eventType }
        return "\(parts[1]) \(parts[0])"
    }
}
