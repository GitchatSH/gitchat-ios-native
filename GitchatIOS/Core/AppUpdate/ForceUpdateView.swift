import SwiftUI
import UIKit

/// Full-screen blocker shown when `AppUpdateChecker.state ==
/// .forceUpdateRequired`. Mounted at `RootView` level via a conditional
/// replace, so SwiftUI tears down all sheets/modals/keyboards by
/// re-rendering the root tree.
///
/// No dismiss gesture, no sign-out, no escape. Single CTA opens the
/// App Store (or TestFlight when this build is sandbox-receipted).
struct ForceUpdateView: View {
    let info: AppUpdateChecker.VersionInfo
    @State private var showStoreSheet = false

    private var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            iconView
            Text("Update Required")
                .font(.title2.bold())
            Text("This version of Gitchat is no longer supported. Please update to continue.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button("Update") { handleUpdateTap() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .sheet(isPresented: $showStoreSheet) {
            AppStoreSheet(
                appStoreId: info.appStoreId,
                fallbackURL: info.storeUrl,
                onDismiss: { showStoreSheet = false }
            )
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let _ = UIImage(named: "AppIcon-Display") {
            Image("AppIcon-Display")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22))
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .resizable()
                .frame(width: 96, height: 96)
                .foregroundStyle(.tint)
        }
    }

    private func handleUpdateTap() {
        if isTestFlight, let url = URL(string: "itms-beta://") {
            UIApplication.shared.open(url)
        } else {
            #if targetEnvironment(simulator)
            UIApplication.shared.open(info.storeUrl)
            #else
            showStoreSheet = true
            #endif
        }
    }
}
