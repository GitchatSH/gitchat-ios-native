import StoreKit
import SwiftUI
import UIKit

struct AppStoreSheet: UIViewControllerRepresentable {
    let appStoreId: String
    let fallbackURL: URL

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
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, SKStoreProductViewControllerDelegate {
        func productViewControllerDidFinish(_ vc: SKStoreProductViewController) {
            vc.dismiss(animated: true)
        }
    }
}
