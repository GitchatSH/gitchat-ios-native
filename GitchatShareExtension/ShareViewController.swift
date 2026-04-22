import UIKit
import SwiftUI

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        guard let extensionContext = self.extensionContext else { return }

        Task { @MainActor in
            let payload = await SharePayloadLoader.load(from: extensionContext)
            let root = ShareRootView(
                payload: payload,
                onCancel: { [weak self] in self?.cancelShare() },
                onSent: { [weak self] in self?.completeShare() }
            )
            let host = UIHostingController(rootView: root)
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    private func cancelShare() {
        extensionContext?.cancelRequest(withError: NSError(domain: "share.cancelled", code: -1))
    }

    private func completeShare() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
