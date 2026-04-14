import SwiftUI

@MainActor
final class LinkGithubViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var error: String?

    func link() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let code = try await GitHubWebOAuth.shared.obtainAuthorizationCode()
            let link = try await APIClient.shared.exchangeGithubCode(
                code: code,
                redirectURI: GitHubWebOAuth.redirectURI
            )
            AuthStore.shared.save(token: link.access_token, login: link.login, needsGithubLink: false)
        } catch GitHubWebOAuth.WebOAuthError.cancelled {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Full-screen wall shown to Apple-only users. The entire Gitchat backend is
/// keyed off a GitHub token in the JWT payload — without one, every authed
/// endpoint returns 401. Force the link before letting the user into the app.
struct LinkGithubWall: View {
    @StateObject private var vm = LinkGithubViewModel()
    @EnvironmentObject var auth: AuthStore

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer().frame(maxHeight: 80)

                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 5)

                VStack(spacing: 10) {
                    Text("One more step")
                        .font(.geist(28, weight: .black))
                        .foregroundStyle(Color(.label))
                    Text("Gitchat is built on top of GitHub.\nLink your GitHub account to unlock chats, friends, and repo activity.")
                        .font(.geist(15, weight: .regular))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color(.secondaryLabel))
                        .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        Task { await vm.link() }
                    } label: {
                        HStack(spacing: 8) {
                            if vm.isLoading {
                                ProgressView().tint(Color(.systemBackground))
                            } else {
                                Image("GitHubMark")
                                    .resizable()
                                    .renderingMode(.template)
                                    .scaledToFit()
                                    .frame(width: 17, height: 17)
                            }
                            Text("Link GitHub")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color(.label))
                        .clipShape(Capsule())
                        .foregroundStyle(Color(.systemBackground))
                    }
                    .disabled(vm.isLoading)

                    Button("Sign out", role: .destructive) {
                        auth.signOut()
                    }
                    .font(.geist(14, weight: .regular))
                }
                .padding(.horizontal, 32)

                if let err = vm.error {
                    Text(err)
                        .font(.geist(12, weight: .regular))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.bottom, 40)
        }
    }
}
