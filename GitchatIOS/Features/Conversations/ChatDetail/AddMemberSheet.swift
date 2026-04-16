import SwiftUI

/// Lightweight modal to add a GitHub user to a group conversation.
struct AddMemberSheet: View {
    let conversationId: String
    var existingLogins: Set<String> = []
    var onAdded: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var login: String = ""
    @State private var submitting = false
    @State private var error: String?
    @State private var friends: [FriendUser] = []
    @State private var loadingFriends = false

    private var trimmed: String {
        login.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }

    private var canSubmit: Bool {
        !trimmed.isEmpty
            && trimmed.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", options: .regularExpression) != nil
            && !submitting
    }

    private var filteredFriends: [FriendUser] {
        let q = login.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        let base = friends.filter { !existingLogins.contains($0.login) }
        if q.isEmpty { return base }
        return base.filter { f in
            f.login.lowercased().contains(q) || (f.name ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub username") {
                    HStack(spacing: 6) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("octocat", text: $login)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { submit() }
                    }
                }
                .listRowBackground(Color.clear)
                if !filteredFriends.isEmpty {
                    Section {
                        ForEach(filteredFriends) { friend in
                            Button {
                                add(login: friend.login)
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarView(url: friend.avatar_url, size: 32, login: friend.login)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(friend.name ?? friend.login)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Color(.label))
                                        Text("@\(friend.login)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Friends")
                    }
                } else if loadingFriends {
                    Section { ProgressView().listRowBackground(Color.clear) }
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .task { await loadFriends() }
            .navigationTitle("Add member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") { submit() }
                        .disabled(!canSubmit)
                        .bold()
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func submit() {
        guard canSubmit else { return }
        add(login: trimmed)
    }

    private func add(login username: String) {
        guard !submitting else { return }
        submitting = true
        error = nil
        Task {
            do {
                try await APIClient.shared.addMember(conversationId: conversationId, login: username)
                ToastCenter.shared.show(.success, "Added @\(username)")
                onAdded?()
                dismiss()
            } catch {
                let msg = error.localizedDescription.lowercased()
                if msg.contains("already") || msg.contains("member") {
                    ToastCenter.shared.show(.warning, "@\(username) is already a member")
                } else {
                    self.error = error.localizedDescription
                }
                submitting = false
            }
        }
    }

    private func loadFriends() async {
        guard friends.isEmpty else { return }
        loadingFriends = true
        defer { loadingFriends = false }
        if let list = try? await APIClient.shared.followingList() {
            // People you follow are surfaced alphabetically — fastest
            // way to recognise a friend by handle.
            let sorted: [FriendUser] = list.sorted(by: { (a: FriendUser, b: FriendUser) -> Bool in
                a.login.lowercased() < b.login.lowercased()
            })
            self.friends = sorted
        }
    }
}
