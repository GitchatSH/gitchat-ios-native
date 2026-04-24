import SwiftUI
import StoreKit

/// Native in-app App Store sheet. Tapping "Update" inside this sheet
/// downloads + installs the new version without the user leaving the
/// app — the closest thing App Review permits to a true in-app update.
///
/// TestFlight builds can't be updated through this controller (it
/// only hits the public App Store). `UpdateSheetRouter` is the entry
/// point that picks the right destination based on
/// `AppDistributionChannel`.
struct AppStoreSheet: UIViewControllerRepresentable {
    let appStoreId: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> SKStoreProductViewController {
        let vc = SKStoreProductViewController()
        vc.delegate = context.coordinator
        vc.loadProduct(
            withParameters: [SKStoreProductParameterITunesItemIdentifier: appStoreId],
            completionBlock: nil
        )
        return vc
    }

    func updateUIViewController(_ uiViewController: SKStoreProductViewController, context: Context) {}

    final class Coordinator: NSObject, SKStoreProductViewControllerDelegate {
        func productViewControllerDidFinish(_ vc: SKStoreProductViewController) {
            vc.dismiss(animated: true)
        }
    }
}

/// Routes "update now" taps to the right destination.
///
/// - Simulator: `SKStoreProductViewController` doesn't work; open the
///   storeUrl in Safari instead so the flow is still testable.
/// - TestFlight: jump to the TestFlight app via `itms-beta://`. The
///   product sheet is not useful for beta builds.
/// - App Store: present `AppStoreSheet` in-app.
enum UpdateSheetRouter {
    enum Destination: Equatable {
        case inAppSheet(appStoreId: String)
        case external(URL)
    }

    static func destination(for info: AppUpdateChecker.VersionInfo) -> Destination {
        switch AppDistributionChannel.current {
        case .appStore:
            return .inAppSheet(appStoreId: info.appStoreId)
        case .testFlight:
            // TestFlight deep-link — falls through to the store URL
            // when TestFlight isn't installed, which is rare on a
            // device that already runs a sandbox build.
            if let testflight = URL(string: "itms-beta://beta.itunes.apple.com/v1/app/\(info.appStoreId)") {
                return .external(testflight)
            }
            return .external(info.storeUrl)
        case .development:
            return .external(info.storeUrl)
        }
    }
}
