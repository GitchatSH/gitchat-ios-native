import SwiftUI

struct DiscoverPeopleList: View {
    @ObservedObject var vm: DiscoverViewModel
    @ObservedObject private var presence = PresenceStore.shared

    var body: some View {
        let rows = vm.peopleRows()
        Group {
            if vm.peopleLoading && rows.isEmpty {
                SkeletonList(count: 10, avatarSize: 40)
            } else if let err = vm.peopleError, rows.isEmpty {
                errorState(err)
            } else if rows.isEmpty {
                emptyState
            } else {
                List(rows) { user in
                    NavigationLink { ProfileView(login: user.login) } label: {
                        HStack(spacing: 12) {
                            ZStack(alignment: .bottomTrailing) {
                                AvatarView(url: user.avatar_url, size: 40, login: user.login)
                                if presence.isOnline(user.login) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 10, height: 10)
                                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                }
                            }
                            VStack(alignment: .leading) {
                                Text(user.name ?? user.login).font(.headline)
                                Text("@\(user.login)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                #if !targetEnvironment(macCatalyst)
                .scrollIndicators(.hidden)
                #endif
            }
        }
        .onAppear { presence.ensure(vm.peopleRows().map(\.login)) }
    }

    private var emptyState: some View {
        let q = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContentUnavailableCompat(
            title: q.isEmpty ? "No mutual follows yet" : "No people match \"\(q)\"",
            systemImage: q.isEmpty ? "person.2" : "magnifyingglass",
            description: q.isEmpty
                ? "Follow people on GitHub to see them here."
                : "Try a different handle or name."
        )
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Couldn't load people").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Retry") { Task { await vm.loadMutuals() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
