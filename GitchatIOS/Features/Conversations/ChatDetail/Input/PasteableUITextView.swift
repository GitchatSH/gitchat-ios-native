import UIKit

/// `UITextView` subclass that intercepts `paste(_:)` when the clipboard
/// holds an image-only payload and forwards the image via
/// `onPasteImage`. Text-only and image+text clipboards fall through to
/// the system's default paste behavior, which inserts the text portion
/// only — matching Telegram's behavior on both iOS and Mac Catalyst.
///
/// `canPerformAction(_:withSender:)` overrides only the image case.
/// For everything else (text, RTF, URL, attributed strings) it defers
/// to `super.canPerformAction` so the standard Paste menu logic remains
/// unchanged.
final class PasteableUITextView: UITextView {
    /// Fires when paste is invoked and the clipboard contains an image
    /// (and no text). The image has already been decoded; the receiver
    /// is responsible for staging it in the composer's send pipeline.
    var onPasteImage: ((UIImage) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        if pb.hasImages, !pb.hasStrings, let img = pb.image {
            onPasteImage?(img)
            return
        }
        super.paste(sender)
    }

#if targetEnvironment(macCatalyst)
    /// Catalyst: bare Return submits via `onReturnSubmit`; Shift+Return
    /// falls through to default newline insertion.
    ///
    /// Implemented via `UIKeyCommand` with
    /// `wantsPriorityOverSystemBehavior = true` rather than
    /// `pressesBegan`. UITextView's `UIKeyInput` text-input pipeline
    /// consumes Return as `\n` on Catalyst before unhandled presses
    /// reach the responder chain, so a `pressesBegan` intercept gets
    /// bypassed and the newline is inserted anyway. The key command
    /// preempts that pipeline; Shift+Return doesn't match (different
    /// modifier flags) so the system inserts the newline as usual.
    var onReturnSubmit: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let plainReturn = UIKeyCommand(
            input: "\r",
            modifierFlags: [],
            action: #selector(handleReturnSubmit)
        )
        plainReturn.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [plainReturn]
    }

    @objc private func handleReturnSubmit() {
        onReturnSubmit?()
    }
#endif
}
