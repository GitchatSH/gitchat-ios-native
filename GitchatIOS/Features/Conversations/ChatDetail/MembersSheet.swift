import SwiftUI

struct MembersSheet: View {
    let participants: [ConversationParticipant]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if participants.isEmpty {
                ContentUnavailableCompat(
                    title: "No members",
                    systemImage: "person.2",
                    description: "This group has no visible members."
                )
            } else {
                List(participants) { p in
                    NavigationLink(value: ProfileLoginRoute(login: p.login)) {
                        HStack(spacing: 12) {
                            AvatarView(url: p.avatar_url, size: 40)
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}
