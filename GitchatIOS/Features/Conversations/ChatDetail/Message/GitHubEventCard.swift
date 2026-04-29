import SwiftUI

struct GitHubEventCard: View {
    let payload: GitHubEventPayload
    let timestamp: String?     // pre-formatted, e.g. "02:20 PM"

    @Environment(\.openURL) private var openURL

    private var style: GitHubEventStyle {
        GitHubEventStyle.from(eventType: payload.eventType)
    }

    private var metaLine: String {
        let who = payload.actor.map { "@\($0)" } ?? "Someone"
        return "\(who) • \(style.verb)"
    }

    private var tappableURL: URL? {
        payload.url.flatMap(URL.init(string:))
    }

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(style.color)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: style.icon)
                            .foregroundStyle(style.color)
                            .font(.subheadline)
                        Text(payload.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        if let timestamp, !timestamp.isEmpty {
                            Text(timestamp)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(metaLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if tappableURL != nil {
                            Image(systemName: "arrow.up.forward")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(tappableURL == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.verb.capitalized) by \(payload.actor ?? "someone"): \(payload.title)")
        .accessibilityHint(tappableURL == nil ? "" : "Opens on GitHub")
    }

    private func handleTap() {
        if let url = tappableURL { openURL(url) }
    }
}

#Preview("Issue opened") {
    GitHubEventCard(
        payload: GitHubEventPayload(
            eventType: "issue_opened",
            title: "[Bug] Clicking wave notification fires error toast instead of opening DM",
            url: "https://github.com/org/repo/issues/201",
            actor: "norwayiscoming",
            githubEventId: "8815949909"
        ),
        timestamp: "02:20 PM"
    )
    .padding(.horizontal, 16)
}

#Preview("Unknown event (fallback)") {
    GitHubEventCard(
        payload: GitHubEventPayload(
            eventType: "pr_opened",
            title: "Add Telegram-style forwarded header",
            url: "https://github.com/org/repo/pull/96",
            actor: "vincent-xbt",
            githubEventId: nil
        ),
        timestamp: "07:50 PM"
    )
    .padding(.horizontal, 16)
}

#Preview("Missing url + actor") {
    GitHubEventCard(
        payload: GitHubEventPayload(
            eventType: "issue_opened",
            title: "Stop send email",
            url: nil,
            actor: nil,
            githubEventId: nil
        ),
        timestamp: "07:10 AM"
    )
    .padding(.horizontal, 16)
}
