import SwiftUI

struct MembersSheet: View {
    let conversationId: String
    let participants: [ConversationParticipant]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthStore
    @ObservedObject private var presence = PresenceStore.shared
    @State private var showAddMember = false
    @State private var followingLogins: Set<String> = []
    @State private var pendingFollow: Set<String> = []
    @State private var followingLoaded = false
    @State private var pendingKick: ConversationParticipant?
    @State private var kicking: Set<String> = []
    @State private var removedLogins: Set<String> = []

    private var visible: [ConversationParticipant] {
        participants.filter { !removedLogins.contains($0.login) }
    }

    private var sorted: [ConversationParticipant] {
        // Online first (alpha within each bucket), offline after.
        let online = visible
            .filter { presence.isOnline($0.login) }
            .sorted { $0.login.lowercased() < $1.login.lowercased() }
        let offline = visible
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
                    ZStack {
                        // Hidden NavigationLink so the row taps push
                        // to the profile without showing the default
                        // disclosure chevron.
                        NavigationLink(value: ProfileLoginRoute(login: p.login)) {
                            EmptyView()
                        }
                        .opacity(0)

                        HStack(spacing: 12) {
                            AvatarView(url: p.avatar_url, size: 40, login: p.login)
                            VStack(alignment: .leading) {
                                Text(p.name ?? p.login).font(.headline)
                                Text("@\(p.login)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            followControl(for: p.login)
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if p.login != auth.login {
                            Button(role: .destructive) {
                                pendingKick = p
                            } label: {
                                Label("Remove", systemImage: "person.fill.xmark")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                #if !targetEnvironment(macCatalyst)
            .scrollContentBackground(.hidden)
            #endif
                #if !targetEnvironment(macCatalyst)
            .scrollIndicators(.hidden)
            #endif
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
        .task { await loadFollowing() }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showAddMember = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .accessibilityLabel("Add member")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showAddMember) {
            AddMemberSheet(
                conversationId: conversationId,
                existingLogins: Set(participants.map(\.login))
            ) {
                dismiss()
            }
        }
        .alert(item: $pendingKick) { member in
            Alert(
                title: Text("Remove @\(member.login)?"),
                message: Text("They'll no longer receive messages from this group."),
                primaryButton: .destructive(Text("Remove")) {
                    Task { await kick(member) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func kick(_ member: ConversationParticipant) async {
        kicking.insert(member.login)
        defer { kicking.remove(member.login) }
        do {
            try await APIClient.shared.kickMember(conversationId: conversationId, login: member.login)
            removedLogins.insert(member.login)
            ToastCenter.shared.show(.success, "Removed @\(member.login)")
        } catch {
            ToastCenter.shared.show(.error, "Couldn't remove", error.localizedDescription)
        }
    }

    @ViewBuilder
    private func followControl(for login: String) -> some View {
        // Hide the button until the following list has been fetched —
        // otherwise we'd briefly show "Follow" on people the user
        // already follows. Also hide for the current user.
        if !followingLoaded || login == auth.login || followingLogins.contains(login) {
            EmptyView()
        } else {
            Button {
                Task { await follow(login) }
            } label: {
                if pendingFollow.contains(login) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 64, height: 28)
                } else {
                    Text("Follow")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color("AccentColor"), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            // The cell is wrapped in a NavigationLink — without this
            // the button tap also pushes the profile.
            .onTapGesture {}
        }
    }

    private func loadFollowing() async {
        if let list = try? await APIClient.shared.followingList() {
            followingLogins = Set(list.map(\.login))
        }
        followingLoaded = true
    }

    private func follow(_ login: String) async {
        pendingFollow.insert(login)
        defer { pendingFollow.remove(login) }
        do {
            try await APIClient.shared.follow(login: login)
            followingLogins.insert(login)
            ToastCenter.shared.show(.success, "Following @\(login)")
        } catch {
            ToastCenter.shared.show(.error, "Couldn't follow", error.localizedDescription)
        }
    }
}
