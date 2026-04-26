import SwiftUI
import UIKit

/// SwiftUI bridge to `PasteableUITextView`. Used by `ChatInputView` on
/// both iOS and Mac Catalyst so a single UITextView subclass owns the
/// paste behavior across platforms.
///
/// Placeholder: UITextView has no native placeholder; we render a
/// `UILabel` overlay, hidden whenever `text` is non-empty.
///
/// Sizing: `isScrollEnabled = false` makes UITextView publish an
/// intrinsic content size that grows with content, matching the
/// pre-existing SwiftUI `TextField(axis:lineLimit: 1...5)` behavior on
/// iOS. The owning `ChatInputView` clamps min/max via SwiftUI frame
/// modifiers; on Catalyst the surrounding pill keeps it visually
/// single-line.
///
/// Return key:
/// - Catalyst: bare Return → `onSubmit` (handled in
///   `PasteableUITextView.pressesBegan`); Shift+Return → newline.
/// - iOS: Return inserts newline; send is via the send button.
///
/// Focus ring: `focusEffect = nil` opts out of the system focus engine
/// to suppress the macOS focus ring on Catalyst.
struct PasteableTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onPasteImage: (UIImage) -> Void
    let focusProxy: ChatInputView.FocusProxy

    func makeUIView(context: Context) -> PasteableUITextView {
        let tv = PasteableUITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.focusEffect = nil
        tv.returnKeyType = .default
        tv.text = text

        let ph = UILabel()
        ph.text = placeholder
        ph.font = tv.font
        ph.textColor = UIColor.placeholderText
        ph.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.leadingAnchor.constraint(equalTo: tv.leadingAnchor),
            ph.topAnchor.constraint(equalTo: tv.topAnchor),
        ])
        ph.isHidden = !text.isEmpty
        context.coordinator.placeholderLabel = ph

        tv.onPasteImage = { [weak tv] img in
            DispatchQueue.main.async {
                context.coordinator.onPasteImage(img)
                _ = tv
            }
        }
        #if targetEnvironment(macCatalyst)
        tv.onReturnSubmit = { context.coordinator.onSubmit() }
        #endif

        focusProxy.setter = { [weak tv] focus in
            guard let tv else { return }
            if focus { tv.becomeFirstResponder() } else { tv.resignFirstResponder() }
        }
        context.coordinator.ownedFocusProxy = focusProxy
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onPasteImage = onPasteImage
        return tv
    }

    func updateUIView(_ tv: PasteableUITextView, context: Context) {
        if tv.text != text { tv.text = text }
        context.coordinator.placeholderLabel?.isHidden = !tv.text.isEmpty
        context.coordinator.placeholderLabel?.text = placeholder
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onPasteImage = onPasteImage
    }

    /// Drives SwiftUI sizing directly. Computes the height needed for the
    /// current text at the proposed width, clamped to:
    /// - 1 line minimum on both platforms
    /// - 1 line maximum on Mac Catalyst (single-line composer)
    /// - 5 lines maximum on iOS (matches the prior `lineLimit(1...5)`)
    ///
    /// This bypasses `intrinsicContentSize`, which SwiftUI was reading as
    /// an unbounded value for an empty `UITextView` with
    /// `isScrollEnabled = false` — causing the composer to render at the
    /// SwiftUI frame's maxHeight regardless of content. iOS 16+ added
    /// this hook precisely so representables can publish their own size.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: PasteableUITextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let lineHeight = uiView.font?.lineHeight ?? 22
        #if targetEnvironment(macCatalyst)
        return CGSize(width: width, height: lineHeight)
        #else
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        let maxH = lineHeight * 5
        let clamped = max(lineHeight, min(maxH, fitted.height))
        return CGSize(width: width, height: clamped)
        #endif
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteableTextField
        weak var ownedFocusProxy: ChatInputView.FocusProxy?
        weak var placeholderLabel: UILabel?
        var onSubmit: () -> Void = {}
        var onPasteImage: (UIImage) -> Void = { _ in }

        init(_ parent: PasteableTextField) { self.parent = parent }

        deinit { ownedFocusProxy?.setter = nil }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            placeholderLabel?.isHidden = !(textView.text ?? "").isEmpty
            textView.invalidateIntrinsicContentSize()
        }
    }
}
