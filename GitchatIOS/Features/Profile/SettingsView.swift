import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthStore
    @StateObject private var blocks = BlockStore.shared
    @StateObject private var store = StoreManager.shared
    @AppStorage("gitchat.pref.messageSound") private var messageSound: Bool = false
    @AppStorage("gitchat.pref.showOnlineStatus") private var showOnlineStatus: Bool = true
    @AppStorage("gitchat.pref.showUnreadBadges") private var showUnreadBadges: Bool = true
    @AppStorage("gitchat.pref.autoplayGifs") private var autoplayGifs: Bool = true
    @AppStorage("gitchat.pref.compactMode") private var compactMode: Bool = false
    @AppStorage("gitchat.pref.appearance") private var appearance: String = "system"
    @State private var showingSignOutConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var deletingAccount = false
    @State private var legalURL: URL?
    @State private var showBlockedList = false
    @State private var showUpgrade = false

    var body: some View {
        List {
            Section("Account") {
                HStack {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(Color.accentColor)
                    Text("Signed in as")
                    Spacer()
                    Text("@\(auth.login ?? "unknown")")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                proRow
            }

            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Toggle("Compact chat rows", isOn: $compactMode)
            }

            Section("Notifications") {
                Toggle("In-app sound on new message", isOn: $messageSound)
                Toggle("Show unread badges", isOn: $showUnreadBadges)
            }

            Section("Privacy & Safety") {
                Toggle("Show my online status", isOn: $showOnlineStatus)
                Toggle("Autoplay GIFs and videos", isOn: $autoplayGifs)
                Button {
                    showBlockedList = true
                } label: {
                    HStack {
                        Text("Blocked users")
                            .foregroundStyle(Color(.label))
                        Spacer()
                        Text("\(blocks.blockedLogins.count)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section("Legal") {
                Button { legalURL = Config.eulaURL } label: {
                    HStack { Text("EULA"); Spacer(); Image(systemName: "arrow.up.right.square") }
                }
                Button { legalURL = Config.termsURL } label: {
                    HStack { Text("Terms of Service"); Spacer(); Image(systemName: "arrow.up.right.square") }
                }
                Button { legalURL = Config.privacyURL } label: {
                    HStack { Text("Privacy Policy"); Spacer(); Image(systemName: "arrow.up.right.square") }
                }
            }
            .foregroundStyle(Color(.label))

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("\(Config.appVersion)").foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    showingSignOutConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign out").bold()
                        Spacer()
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        if deletingAccount {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Delete account").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(deletingAccount)
            } footer: {
                Text("Permanently removes your Gitchat account. This can't be undone.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Sign out of Gitchat?", isPresented: $showingSignOutConfirm) {
            Button("Sign out", role: .destructive) { auth.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to sign in again to see your chats.")
        }
        .alert("Delete your Gitchat account?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your profile, conversations, and follows will be permanently removed. This can't be undone.")
        }
        .sheet(item: Binding<URLIdentifiableSettings?>(
            get: { legalURL.map(URLIdentifiableSettings.init) },
            set: { legalURL = $0?.url }
        )) { wrapped in
            SafariSheet(url: wrapped.url).ignoresSafeArea()
        }
        .sheet(isPresented: $showBlockedList) {
            NavigationStack { BlockedUsersView() }
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeView()
        }
    }

    private func deleteAccount() async {
        deletingAccount = true
        defer { deletingAccount = false }
        do {
            try await APIClient.shared.deleteAccount()
            ToastCenter.shared.show(.success, "Account deleted")
            auth.signOut()
        } catch {
            ToastCenter.shared.show(.error, "Couldn't delete", error.localizedDescription)
        }
    }

    private var proRow: some View {
        Button {
            showUpgrade = true
        } label: {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("Plan")
                    .foregroundStyle(Color(.label))
                Spacer()
                Text(store.isPro ? "Pro" : "Free")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct BlockedUsersView: View {
    @StateObject private var blocks = BlockStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if blocks.blockedLogins.isEmpty {
                ContentUnavailableCompat(
                    title: "Nobody blocked",
                    systemImage: "hand.raised",
                    description: "Users you block won't appear in your chats or search."
                )
            } else {
                List {
                    ForEach(Array(blocks.blockedLogins).sorted(), id: \.self) { login in
                        HStack {
                            Image(systemName: "person.crop.circle.badge.xmark")
                                .foregroundStyle(.red)
                            Text("@\(login)")
                            Spacer()
                            Button("Unblock") { blocks.unblock(login) }
                                .font(.geist(13, weight: .semibold))
                        }
                    }
                }
            }
        }
        .navigationTitle("Blocked users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}

private struct URLIdentifiableSettings: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
