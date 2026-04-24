import SwiftUI
import UIKit

/// Observes `UIPasteboard` for image content and exposes a
/// `pendingImage` the chat composer can offer as a one-tap paste chip.
///
/// Deduplication is keyed on `UIPasteboard.changeCount` rather than a
/// content hash of the image bitmap. `pngData()?.hashValue` re-encodes
/// the decoded UIImage to PNG on the main thread every refresh — for
/// a full-resolution photo that's ~200–500ms of stall, and it fires
/// on every pasteboard write including ones this app just made. The
/// `changeCount` approach is O(1) and captures exactly the semantic
/// we want: "don't re-prompt the user about a clipboard state they
/// already dismissed".
///
/// Self-origin suppression: whenever any in-app code path writes to
/// the system pasteboard (e.g. "Copy Image" in the chat menu), it
/// updates `selfOriginChangeCount` to the resulting change count.
/// All watcher instances (one `@StateObject` per open chat detail)
/// then short-circuit the refresh triggered by that write. Without
/// this, each "Copy Image" tap stalls the main thread decoding the
/// image we literally just published, only to offer the user a chip
/// to paste it back into the same chat — a nonsensical prompt.
@MainActor
final class ClipboardWatcher: ObservableObject {
    @Published private(set) var pendingImage: UIImage?
    private var dismissedAtChangeCount: Int = -1

    /// Set by any code path that programmatically writes to
    /// `UIPasteboard.general` within the app. Watchers compare against
    /// their own read of `changeCount` to recognise a self-write and
    /// skip the refresh work it would otherwise trigger.
    nonisolated(unsafe) static var selfOriginChangeCount: Int = -1

    /// Convenience for copy paths. Call *after* the pasteboard write —
    /// at that point `changeCount` reflects the new value, which is
    /// what watchers will see when the notification fires.
    static func markSelfOriginWrite() {
        selfOriginChangeCount = UIPasteboard.general.changeCount
    }

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
        let changeCount = UIPasteboard.general.changeCount

        // Self-origin short-circuit — we wrote this, no point decoding
        // our own bytes just to offer the user a paste suggestion for
        // content they literally just published.
        if changeCount == Self.selfOriginChangeCount {
            return
        }

        if changeCount == dismissedAtChangeCount {
            pendingImage = nil
            return
        }

        guard UIPasteboard.general.hasImages,
              let img = UIPasteboard.general.image else {
            pendingImage = nil
            return
        }
        pendingImage = img
    }

    func consume() {
        // Called when the user accepts the paste — don't re-surface the
        // same clipboard state after they've already acted on it.
        dismissedAtChangeCount = UIPasteboard.general.changeCount
        pendingImage = nil
    }

    func dismiss() {
        dismissedAtChangeCount = UIPasteboard.general.changeCount
        pendingImage = nil
    }
}
