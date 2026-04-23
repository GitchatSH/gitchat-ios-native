import SwiftUI
import UIKit

/// Manage a group's invite link — create (or load current), copy, share,
/// revoke + regenerate. Admin-level action; BE will reject with 403 for
/// non-members so we surface the error as a toast.
struct GroupInviteLinkSheet: View {
    let conversationId: String
    let groupName: String?

    @Environment(\.dismiss) private var dismiss
    @State private var link: APIClient.InviteLink?
    @State private var loading = true
    @State private var regenerating = false
    @State private var errorMessage: String?
    @State private var presentedShare: ActivityItems?

    /// Always share the custom-scheme URL so the tap opens the app
    /// directly. BE may also return an `https://dev.gitchat.sh/invite/…`
    /// URL but that route isn't live (404s in Safari) and we haven't
    /// set up Universal Links, so web URLs are useless for recipients
    /// right now — tracked in docs/be-blockers.md.
    private var sharedURL: String? {
        link.map { "gitchat://invite/\($0.code)" }
    }

    private var shareText: String? {
        guard let url = sharedURL else { return nil }
        let label = groupName.map { "Join \"\($0)\" on Gitchat: " } ?? "Join my group on Gitchat: "
        return label + url
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading && link == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage, link == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(error).multilineTextAlignment(.center)
                        Button("Retry") { Task { await load() } }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let link {
                    linkBody(link)
                }
            }
            .navigationTitle("Invite link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(item: $presentedShare) { items in
                ActivityView(items: items.items)
            }
        }
    }

    @ViewBuilder
    private func linkBody(_ link: APIClient.InviteLink) -> some View {
        let display = "gitchat://invite/\(link.code)"
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Anyone with this link can join the group.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(display)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                if let expires = link.expires_at, !expires.isEmpty {
                    Label("Expires \(expires)", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = display
                        ToastCenter.shared.show(.success, "Copied invite link")
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        if let text = shareText {
                            presentedShare = ActivityItems(items: [text])
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        Task { await regenerate() }
                    } label: {
                        if regenerating {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Revoke & regenerate", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(regenerating)
                }
            }
            .padding()
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            link = try await APIClient.shared.createInviteLink(conversationId: conversationId)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func regenerate() async {
        regenerating = true
        defer { regenerating = false }
        do {
            try await APIClient.shared.revokeInviteLink(conversationId: conversationId)
            link = try await APIClient.shared.createInviteLink(conversationId: conversationId)
            ToastCenter.shared.show(.success, "New invite link generated")
        } catch {
            ToastCenter.shared.show(.error, "Couldn't regenerate", error.localizedDescription)
        }
    }
}

private struct ActivityItems: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
