import SwiftUI

struct SeenBySheet: View {
    let message: Message
    let readCursors: [String: String]
    let participants: [ConversationParticipant]
    let myLogin: String?
    @State private var tab = 0
    @Environment(\.dismiss) private var dismiss

    private var seenLogins: [String] {
        let msgDate = message.created_at ?? ""
        return readCursors.compactMap { login, readAt in
            guard login != myLogin else { return nil }
            return readAt >= msgDate ? login : nil
        }.sorted()
    }

    private var notSeenLogins: [String] {
        let seen = Set(seenLogins)
        return participants
            .map(\.login)
            .filter { $0 != myLogin && !seen.contains($0) }
            .sorted()
    }

    private func participant(for login: String) -> ConversationParticipant? {
        participants.first { $0.login == login }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Seen (\(seenLogins.count))").tag(0)
                Text("Not seen (\(notSeenLogins.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            if tab == 0 {
                if seenLogins.isEmpty {
                    ContentUnavailableCompat(
                        title: "No one yet",
                        systemImage: "eye.slash",
                        description: "No one has seen this message yet."
                    )
                } else {
                    List(seenLogins, id: \.self) { login in
                        userRow(login: login)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            } else {
                if notSeenLogins.isEmpty {
                    ContentUnavailableCompat(
                        title: "Everyone has seen it",
                        systemImage: "eye",
                        description: "All members have seen this message."
                    )
                } else {
                    List(notSeenLogins, id: \.self) { login in
                        userRow(login: login)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
        }
        .navigationTitle("Seen by")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func userRow(login: String) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                url: participant(for: login)?.avatar_url,
                size: 36,
                login: login
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(participant(for: login)?.name ?? login)
                    .font(.subheadline.weight(.semibold))
                Text("@\(login)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if tab == 0, let readAt = readCursors[login] {
                Text(RelativeTime.format(readAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
