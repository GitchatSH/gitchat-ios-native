import SwiftUI

struct MembersSheet: View {
    let participants: [ConversationParticipant]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var presence = PresenceStore.shared

    private var sorted: [ConversationParticipant] {
        // Online first (by the usual alpha ordering within each
        // group), offline after.
        let online = participants
            .filter { presence.isOnline($0.login) }
            .sorted { $0.login.lowercased() < $1.login.lowercased() }
        let offline = participants
            .filter { !presence.isOnline($0.login) }
            .sorted { $0.login.lowercased() < $1.login.lowercased() }
        return online + offline
    }

    var body: some View {
        Group {
            if participants.isEmpty {
                ContentUnavailableCompat(
                    title: "No members",
                    systemImage: "person.2",
                    description: "This group has no visible members."
                )
            } else {
                List(sorted) { p in
                    NavigationLink(value: ProfileLoginRoute(login: p.login)) {
                        HStack(spacing: 12) {
                            AvatarView(url: p.avatar_url, size: 40, login: p.login)
                            VStack(alignment: .leading) {
                                Text(p.name ?? p.login).font(.headline)
                                Text("@\(p.login)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("\(participants.count) Member\(participants.count == 1 ? "" : "s")")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ProfileLoginRoute.self) { route in
            ProfileView(login: route.login)
        }
        .onAppear {
            presence.ensure(participants.map(\.login))
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}
