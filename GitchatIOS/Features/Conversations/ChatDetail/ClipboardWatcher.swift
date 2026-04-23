import SwiftUI
import UIKit

/// Observes `UIPasteboard` for image content and exposes a
/// `pendingImage` the chat composer can offer as a one-tap paste chip.
///
/// Deduplication: when the user dismisses a pasted image suggestion,
/// the hash of its bitmap is remembered in-memory so the same clipboard
/// contents don't re-prompt until the clipboard changes again.
/// Not persisted.
@MainActor
final class ClipboardWatcher: ObservableObject {
    @Published private(set) var pendingImage: UIImage?
    private var dismissedHash: Int?

    init() {
        NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard UIPasteboard.general.hasImages,
              let img = UIPasteboard.general.image else {
            pendingImage = nil
            return
        }
        let h = img.pngData()?.hashValue ?? 0
        if h == dismissedHash {
            pendingImage = nil
            return
        }
        pendingImage = img
    }

    func consume() {
        // Called when the user accepts the paste — don't re-surface the
        // same image after they've already acted on it.
        dismissedHash = pendingImage?.pngData()?.hashValue
        pendingImage = nil
    }

    func dismiss() {
        if let img = pendingImage {
            dismissedHash = img.pngData()?.hashValue
        }
        pendingImage = nil
    }
}
