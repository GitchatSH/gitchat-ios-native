import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthStore
    @AppStorage("gitchat.pref.messageSound") private var messageSound: Bool = false
    @AppStorage("gitchat.pref.showOnlineStatus") private var showOnlineStatus: Bool = true
    @AppStorage("gitchat.pref.showUnreadBadges") private var showUnreadBadges: Bool = true
    @AppStorage("gitchat.pref.autoplayGifs") private var autoplayGifs: Bool = true
    @AppStorage("gitchat.pref.compactMode") private var compactMode: Bool = false
    @AppStorage("gitchat.pref.appearance") private var appearance: String = "system"
    @State private var showingSignOutConfirm = false
    @State private var legalURL: URL?

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

            Section("Privacy") {
                Toggle("Show my online status", isOn: $showOnlineStatus)
                Toggle("Autoplay GIFs and videos", isOn: $autoplayGifs)
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
                HStack {
                    Text("API")
                    Spacer()
                    Text(Config.apiBaseURL.host ?? "")
                        .foregroundStyle(.secondary)
                        .font(.system(.caption, design: .monospaced))
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
    }
}

private struct URLIdentifiableSettings: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
