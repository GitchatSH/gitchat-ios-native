import Foundation
import AuthenticationServices

@MainActor
final class GitHubWebOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GitHubWebOAuth()

    // Must match the Authorization callback URL configured on the OAuth App.
    static let redirectURI = "gitchat://oauth-callback"
    private static let callbackScheme = "gitchat"

    enum WebOAuthError: LocalizedError {
        case cancelled
        case missingCode(String?)
        case badURL
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign in was cancelled"
            case .missingCode(let err):
                return err.map { "GitHub: \($0)" } ?? "GitHub did not return an authorization code"
            case .badURL: return "Could not build the authorize URL"
            }
        }
    }

    /// Opens ASWebAuthenticationSession against GitHub, captures the redirect, and
    /// returns the authorization `code`. If the user is already signed into
    /// GitHub in Safari and has previously authorized this OAuth App, GitHub
    /// auto-redirects with no UI at all.
    func obtainAuthorizationCode() async throws -> String {
        var comps = URLComponents(string: "https://github.com/login/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Config.githubClientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Config.githubScope),
            URLQueryItem(name: "allow_signup", value: "true")
        ]
        guard let url = comps.url else { throw WebOAuthError.badURL }

        let callbackURL: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { callback, error in
                if let error {
                    let ns = error as NSError
                    if ns.domain == "com.apple.AuthenticationServices.WebAuthenticationSession",
                       ns.code == 1 {
                        cont.resume(throwing: WebOAuthError.cancelled)
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                if let callback {
                    cont.resume(returning: callback)
                } else {
                    cont.resume(throwing: WebOAuthError.missingCode(nil))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let code = items.first(where: { $0.name == "code" })?.value {
            return code
        }
        let err = items.first(where: { $0.name == "error_description" })?.value
            ?? items.first(where: { $0.name == "error" })?.value
        throw WebOAuthError.missingCode(err)
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}
