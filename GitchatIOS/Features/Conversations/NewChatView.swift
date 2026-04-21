import SwiftUI

@MainActor
final class NewChatViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [FriendUser] = []
    @Published var friends: [FriendUser] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var creating = false
    @Published var groupMode = false
    @Published var selected: [FriendUser] = []
    @Published var groupName: String = ""

    private var debounceTask: Task<Void, Never>?

    func loadFriends() async {
        do { friends = try await APIClient.shared.followingList() } catch { }
    }

    func queryChanged(_ text: String) {
        debounceTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            results = []
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await self?.search(q)
        }
    }

    private func search(_ q: String) async {
        isLoading = true; error = nil
        defer { isLoading = false }
        AnalyticsTracker.trackSearch(query: q)
        do {
            results = try await APIClient.shared.searchUsersForDM(query: q)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggle(_ u: FriendUser) {
        if let i = selected.firstIndex(where: { $0.login == u.login }) {
            selected.remove(at: i)
        } else {
            selected.append(u)
        }
    }

    func isSelected(_ u: FriendUser) -> Bool {
        selected.contains(where: { $0.login == u.login })
    }

    func startDM(with login: String) async -> Conversation? {
        creating = true; defer { creating = false }
        do {
            let convo = try await APIClient.shared.createConversation(recipient: login)
            AnalyticsTracker.trackConversationStarted(isGroup: false)
            return convo
        }
        catch { self.error = error.localizedDescription; return nil }
    }

    func createGroupChat() async -> Conversation? {
        guard !selected.isEmpty else { return nil }
        creating = true; defer { creating = false }
        do {
            let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            let convo = try await APIClient.shared.createGroup(
                recipients: selected.map(\.login),
                name: name.isEmpty ? nil : name
            )
            AnalyticsTracker.trackConversationStarted(isGroup: true)
            return convo
        } catch { self.error = error.localizedDescription; return nil }
    }

    var visibleUsers: [FriendUser] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count >= 2 { return results }
        // No query — show followed friends as the default suggestion set
        return friends
    }
}

struct NewChatView: View {
    @StateObject private var vm = NewChatViewModel()
    @Environment(\.dismiss) private var dismiss
    let onOpen: (Conversation) -> Void
    @State private var showGroupNameAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if vm.groupMode, !vm.selected.isEmpty {
                    selectionBar
                }
                list
            }
            .onChange(of: vm.error) { newValue in
                if let msg = newValue, !msg.isEmpty {
                    ToastCenter.shared.show(.error, "Couldn't start chat", cleanErrorMessage(msg))
                    vm.error = nil
                }
            }
            .searchable(
                text: $vm.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search by handle or name"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onChange(of: vm.query) { vm.queryChanged($0) }
            .navigationTitle(vm.groupMode ? "New group" : "New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if vm.groupMode {
                        Button("Create") {
                            vm.groupName = ""
                            showGroupNameAlert = true
                        }
                        .disabled(vm.selected.isEmpty || vm.creating)
                        .font(.geist(15, weight: .semibold))
                    } else {
                        Button("New Group") {
                            vm.groupMode = true
                        }
                        .font(.geist(15, weight: .semibold))
                    }
                }
            }
            .overlay {
                if vm.creating { loadingOverlay }
            }
            .alert("Name this group", isPresented: $showGroupNameAlert) {
                TextField("Group name (optional)", text: $vm.groupName)
                Button("Create") {
                    Task {
                        if let convo = await vm.createGroupChat() {
                            onOpen(convo); dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave it blank to use participants' names.")
            }
            .task { await vm.loadFriends() }
        }
    }

    private var selectionBar: some View {
        HStack {
            Text("\(vm.selected.count) selected")
                .font(.geist(12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Spacer()
            Button("Clear") { vm.selected.removeAll() }
                .font(.geist(12, weight: .semibold))
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var list: some View {
        Group {
            if vm.visibleUsers.isEmpty && !vm.isLoading {
                if vm.query.isEmpty {
                    ContentUnavailableCompat(
                        title: "No friends yet",
                        systemImage: "person.2",
                        description: "Search above to find anyone on GitHub."
                    )
                } else if vm.query.count >= 2 {
                    ContentUnavailableCompat(
                        title: "No matches",
                        systemImage: "person.slash",
                        description: "Try a different handle."
                    )
                } else {
                    Spacer()
                }
            } else {
                List(vm.visibleUsers) { user in
                    row(for: user)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(for user: FriendUser) -> some View {
        let selected = vm.isSelected(user)
        return Button {
            if vm.groupMode {
                vm.toggle(user)
            } else {
                Task {
                    if let convo = await vm.startDM(with: user.login) {
                        onOpen(convo); dismiss()
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: user.avatar_url, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text((user.name?.isEmpty == false ? user.name! : user.login))
                        .font(.geist(15, weight: .semibold))
                        .foregroundStyle(Color(.label))
                    Text("@\(user.login)")
                        .font(.geist(12, weight: .regular))
                        .foregroundStyle(Color(.secondaryLabel))
                }
                Spacer()
                if vm.groupMode {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : Color(.tertiaryLabel))
                } else if user.online == true {
                    Circle().fill(.green).frame(width: 8, height: 8)
                }
            }
            .padding(10)
            .background(
                selected ? Color.accentColor.opacity(0.08) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cleanErrorMessage(_ raw: String) -> String {
        // Pull out the human-readable `"message":"..."` from backend HTTP error blobs.
        if let range = raw.range(of: #""message"\s*:\s*"([^"]+)""#, options: .regularExpression) {
            let slice = raw[range]
            if let m = slice.range(of: #""([^"]+)"$"#, options: .regularExpression) {
                return String(slice[m]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return raw
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            ProgressView().tint(.white).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
