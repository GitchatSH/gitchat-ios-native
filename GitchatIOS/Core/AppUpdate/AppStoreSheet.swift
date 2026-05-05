import StoreKit
import SwiftUI
import UIKit

struct AppStoreSheet: UIViewControllerRepresentable {
    let appStoreId: String
    let fallbackURL: URL
    /// Called when the user dismisses the App Store product view controller.
    /// Required because UIKit's `vc.dismiss(animated:)` does not flip the
    /// SwiftUI `.sheet(isPresented:)` binding — without this callback, the
    /// caller's `@State` stays `true` and the sheet refuses to re-present.
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> SKStoreProductViewController {
        let vc = SKStoreProductViewController()
        vc.delegate = context.coordinator

        #if targetEnvironment(simulator)
        NSLog("[AppStoreSheet] simulator: SKStoreProductViewController is a no-op; would open \(fallbackURL.absoluteString)")
        #else
        let params = [SKStoreProductParameterITunesItemIdentifier: appStoreId]
        vc.loadProduct(withParameters: params) { [fallbackURL] success, _ in
            if !success {
                NSLog("[AppStoreSheet] loadProduct failed; opening fallback URL")
                DispatchQueue.main.async { UIApplication.shared.open(fallbackURL) }
            }
        }
        #endif

        return vc
    }

    func updateUIViewController(_: SKStoreProductViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, SKStoreProductViewControllerDelegate {
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func productViewControllerDidFinish(_ vc: SKStoreProductViewController) {
            vc.dismiss(animated: true)
            onDismiss()
        }
    }
}
