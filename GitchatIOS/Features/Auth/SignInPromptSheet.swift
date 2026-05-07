import SwiftUI

enum SignInReason: Equatable {
    case wave(login: String)
    case dm(login: String)
    case follow(login: String)
    case post
    case react
    case invite

    var title: String {
        switch self {
        case .wave(let login):   return "Sign in to wave at @\(login)"
        case .dm(let login):     return "Sign in to message @\(login)"
        case .follow(let login): return "Sign in to follow @\(login)"
        case .post:              return "Sign in to post"
        case .react:             return "Sign in to react"
        case .invite:            return "Sign in to join the group"
        }
    }
}

extension SignInReason: Identifiable {
    public var id: String {
        switch self {
        case .wave(let l):   return "wave:\(l)"
        case .dm(let l):     return "dm:\(l)"
        case .follow(let l): return "follow:\(l)"
        case .post:          return "post"
        case .react:         return "react"
        case .invite:        return "invite"
        }
    }
}

/// Bottom sheet shown when a guest taps a locked action. Wraps the
/// existing `SignInViewModel.startGithub()` flow so the sign-in path
/// is identical to the SignInView GitHub button.
struct SignInPromptSheet: View {
    let reason: SignInReason
    let onDismiss: () -> Void
    @StateObject private var vm = SignInViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var didTapSignIn = false

    var body: some View {
        VStack(spacing: 20) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.top, 24)
            Text(reason.title)
                .font(.geist(20, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("Gitchat uses your GitHub identity to send waves, message developers, and post in groups.")
                .font(.geist(13, weight: .regular))
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                didTapSignIn = true
                AnalyticsTracker.trackGuestSignInPromptTapped(reason: reason.id)
                Task {
                    await vm.startGithub()
                    if AuthStore.shared.isAuthenticated {
                        dismiss()
                        onDismiss()
                    }
                }
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
            .padding(.horizontal, 24)
            .disabled(vm.isLoading)

            Button("Not now") { dismiss() }
                .font(.geist(13, weight: .regular))
                .foregroundStyle(Color(.secondaryLabel))
                .padding(.bottom, 24)

            if let err = vm.error {
                Text(err)
                    .font(.geist(12, weight: .regular))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .presentationDetents([.fraction(0.55)])
        .presentationDragIndicator(.visible)
        .onAppear {
            AnalyticsTracker.trackGuestSignInPromptShown(reason: reason.id)
        }
        .onDisappear {
            // If the user dismissed without converting, fire dismissed.
            // If they tapped Sign in and AuthStore is authed, the
            // RootView shell swap handled the transition — that's a
            // success, not a dismissal.
            if !didTapSignIn || !AuthStore.shared.isAuthenticated {
                AnalyticsTracker.trackGuestSignInPromptDismissed(reason: reason.id)
            }
        }
    }
}
