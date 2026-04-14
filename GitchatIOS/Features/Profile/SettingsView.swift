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
    @State private var legalURL: URL?
    @State private var showBlockedList = false
    @State private var showUpgrade = false

    var body: some View {
        List {
            Section {
                proRow
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                Button("Restore purchases") {
                    Task { try? await store.restore() }
                }
                .font(.caption)
            }

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
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Sign out of Gitchat?",
            isPresented: $showingSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { auth.signOut() }
            Button("Cancel", role: .cancel) {}
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

    @ViewBuilder
    private var proRow: some View {
        if store.isPro {
            HStack(spacing: 12) {
                Image(systemName: "star.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Gitchat Pro")
                            .font(.geist(16, weight: .bold))
                            .foregroundStyle(.white)
                        proBadge
                    }
                    Text("You're a Pro supporter. Thank you!")
                        .font(.geist(12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.3), radius: 10, y: 4)
        } else {
            Button {
                showUpgrade = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upgrade to Pro")
                            .font(.geist(16, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Unlimited history, larger uploads, custom themes, Pro badge.")
                            .font(.geist(12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.75)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.accentColor.opacity(0.3), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
        }
    }

    private var proBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill").font(.system(size: 9))
            Text("PRO").font(.system(size: 10, weight: .heavy))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Color.white)
        .clipShape(Capsule())
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
