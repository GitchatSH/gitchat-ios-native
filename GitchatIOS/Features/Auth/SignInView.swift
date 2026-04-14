import SwiftUI

@MainActor
final class SignInViewModel: ObservableObject {
    @Published var deviceCode: GitHubDeviceFlow.DeviceCode?
    @Published var isLoading = false
    @Published var error: String?

    func start() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let code = try await GitHubDeviceFlow.requestDeviceCode()
            self.deviceCode = code
            UIPasteboard.general.string = code.user_code
            if let url = URL(string: code.verification_uri) {
                await UIApplication.shared.open(url)
            }
            let ghToken = try await GitHubDeviceFlow.pollForToken(
                deviceCode: code.device_code,
                interval: code.interval,
                expiresIn: code.expires_in
            )
            let link = try await APIClient.shared.linkGithub(githubToken: ghToken)
            AuthStore.shared.save(token: link.access_token, login: link.login)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SignInView: View {
    @StateObject private var vm = SignInViewModel()

    var body: some View {
        ZStack {
            Color.accentColor.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 96, weight: .bold))
                    .foregroundStyle(.white)
                Text("Gitchat")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("Chat with developers,\nwithout leaving your flow.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))

                Spacer()

                if let code = vm.deviceCode {
                    VStack(spacing: 12) {
                        Text("Your code")
                            .foregroundStyle(.white.opacity(0.8))
                        Text(code.user_code)
                            .font(.system(size: 36, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24).padding(.vertical, 12)
                            .background(.white.opacity(0.15), in: .rect(cornerRadius: 16))
                        Text("Enter it at \(code.verification_uri)")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                        ProgressView().tint(.white)
                    }
                } else {
                    Button {
                        Task { await vm.start() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.right.circle.fill")
                            Text("Sign in with GitHub").bold()
                        }
                        .font(.headline)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                        .background(.white, in: .capsule)
                        .foregroundStyle(Color.accentColor)
                    }
                    .disabled(vm.isLoading)
                    .padding(.horizontal, 32)
                }

                if let error = vm.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding()
        }
    }
}
