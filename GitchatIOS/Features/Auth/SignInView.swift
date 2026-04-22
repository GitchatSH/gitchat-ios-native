import SwiftUI
import UIKit
import AuthenticationServices

@MainActor
final class SignInViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var error: String?

    func startGithub() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let code = try await GitHubWebOAuth.shared.obtainAuthorizationCode()
            let link = try await APIClient.shared.exchangeGithubCode(
                code: code,
                redirectURI: GitHubWebOAuth.redirectURI
            )
            AuthStore.shared.save(token: link.access_token, login: link.login, method: "github")
        } catch GitHubWebOAuth.WebOAuthError.cancelled {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                self.error = "Apple did not return an identity token"
                return
            }
            let first = cred.fullName?.givenName
            let last = cred.fullName?.familyName
            Task { [weak self] in
                guard let self else { return }
                do {
                    let resp = try await APIClient.shared.appleLink(
                        identityToken: token,
                        firstName: first,
                        lastName: last
                    )
                    await MainActor.run {
                        AuthStore.shared.save(
                            token: resp.access_token,
                            login: resp.login,
                            needsGithubLink: resp.needs_github_link,
                            method: "apple"
                        )
                    }
                } catch {
                    await MainActor.run { self.error = error.localizedDescription }
                }
            }
        case .failure(let err):
            let ns = err as NSError
            if ns.domain == ASAuthorizationError.errorDomain, ns.code == ASAuthorizationError.canceled.rawValue {
                return
            }
            self.error = err.localizedDescription
        }
    }
}

// MARK: - Geist font helper

extension Font {
    static func geist(_ size: CGFloat, weight: GeistWeight = .regular) -> Font {
        .custom(weight.rawValue, size: size)
    }

    enum GeistWeight: String {
        case regular  = "Geist-Regular"
        case semibold = "Geist-SemiBold"
        case bold     = "Geist-Bold"
        case black    = "Geist-Black"
    }
}

struct SignInView: View {
    @StateObject private var vm = SignInViewModel()
    @Environment(\.colorScheme) private var colorScheme
    @State private var legalURL: URL?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer().frame(maxHeight: 80)
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                Text("Gitchat")
                    .font(.geist(44, weight: .black))
                    .foregroundStyle(Color(.label))
                Text("Chat with developers,\nwithout leaving your flow.")
                    .font(.geist(18, weight: .regular))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(.secondaryLabel))

                Spacer()

                VStack(spacing: 12) {
                    // Sign in with GitHub
                    Button {
                        Task { await vm.startGithub() }
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
                            Text("Sign in with GitHub")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color(.label))
                        .clipShape(Capsule())
                        .foregroundStyle(Color(.systemBackground))
                    }
                    .disabled(vm.isLoading)

                    // Sign in with Apple
                    SignInWithAppleButton(
                        .signIn,
                        onRequest: { req in
                            req.requestedScopes = [.fullName, .email]
                        },
                        onCompletion: { result in
                            vm.handleApple(result)
                        }
                    )
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 32)

                legalDisclaimer

                if let error = vm.error {
                    Text(error)
                        .font(.geist(13, weight: .regular))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .sheet(item: Binding<URLIdentifiable?>(
            get: { legalURL.map(URLIdentifiable.init) },
            set: { legalURL = $0?.url }
        )) { wrapped in
            SafariSheet(url: wrapped.url).ignoresSafeArea()
        }
    }

    private var legalDisclaimer: some View {
        VStack(spacing: 6) {
            Text("By signing in, you agree to Gitchat's terms below.")
                .font(.geist(11, weight: .regular))
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button("EULA") { legalURL = Config.eulaURL }
                Text("·").foregroundStyle(Color(.tertiaryLabel))
                Button("Terms") { legalURL = Config.termsURL }
                Text("·").foregroundStyle(Color(.tertiaryLabel))
                Button("Privacy") { legalURL = Config.privacyURL }
            }
            .font(.geist(11, weight: .semibold))
            .foregroundStyle(Color("AccentColor"))
        }
        .padding(.horizontal, 32)
    }
}

private struct URLIdentifiable: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
