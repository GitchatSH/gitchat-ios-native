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
            // The backend issues a new JWT tied to the real GitHub login.
            AuthStore.shared.save(token: link.access_token, login: link.login, needsGithubLink: false)
        } catch GitHubWebOAuth.WebOAuthError.cancelled {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LinkGithubBanner: View {
    @StateObject private var vm = LinkGithubViewModel()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image("GitHubMark")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Link your GitHub account")
                        .font(.geist(14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Unlock chats, friends, and repo activity.")
                        .font(.geist(12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Button {
                    Task { await vm.link() }
                } label: {
                    if vm.isLoading {
                        ProgressView().tint(.white).frame(width: 60)
                    } else {
                        Text("Link")
                            .font(.geist(14, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Color.white)
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                .disabled(vm.isLoading)
            }
            if let err = vm.error {
                Text(err)
                    .font(.geist(11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.accentColor)
    }
}
