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
    /// falls through to default newline insertion. Tracked here rather
    /// than in `UITextViewDelegate.shouldChangeTextIn:` because the
    /// text-replacement callback does not carry modifier-flag context.
    var onReturnSubmit: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if key.keyCode == .keyboardReturnOrEnter {
                if key.modifierFlags.contains(.shift) {
                    super.pressesBegan(presses, with: event)
                    return
                }
                onReturnSubmit?()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }
#endif
}
