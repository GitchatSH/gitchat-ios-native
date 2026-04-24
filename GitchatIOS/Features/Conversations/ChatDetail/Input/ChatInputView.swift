import SwiftUI
import PhotosUI
import UIKit

/// Composer bar sitting above the keyboard. Combines:
/// - Attach button (PhotosPicker → routes through the parent's drop
///   preview flow).
/// - Text field (multi-line on iOS; single-line on Mac Catalyst so
///   Return triggers `.onSubmit`).
/// - Send button (disabled when draft is empty or an upload is in
///   flight).
///
/// Auxiliary surfaces that sit ABOVE the composer (reply/edit bar,
/// mention suggestions, clipboard chip) live in dedicated files in
/// this folder and are composed by the owning view.
///
/// Keyboard glue: the composer itself does not own keyboard state —
/// the enclosing `ChatView` drives the bottom inset via
/// `KeyboardState.height` + `KeyboardState.lastChange.swiftUIAnimation`.
/// That keeps this view stateless about the keyboard and lets it be
/// rehosted (e.g. in a preview) without observing system events.
struct ChatInputView: View {
    @Environment(\.chatTheme) private var theme

    @Binding var draft: String
    @Binding var photoItems: [PhotosPickerItem]
    let mode: Mode
    let isUploading: Bool
    let onSend: () -> Void
    let onSubmitMacCatalyst: () -> Void

    /// Controls the placeholder + send glyph semantics.
    enum Mode {
        case message
        case editing
        case replying
    }

    @FocusState private var focused: Bool

    /// External bridge so the parent view can gate focus explicitly
    /// (e.g. after a Reply action completes). Mirrors the bubbleless
    /// `@FocusState.Binding` pattern without leaking focus state.
    let focusProxy: FocusProxy

    final class FocusProxy: ObservableObject {
        fileprivate var setter: ((Bool) -> Void)?
        func focus() { setter?(true) }
        func blur() { setter?(false) }
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
        // Whole composer as one Tahoe-style floating pill, matching
        // `MacBottomNav` inner/outer padding so sidebar nav + detail
        // composer sit level on the same horizontal row.
        HStack(spacing: 4) {
            attachButton
            textField
            sendButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .macFloatingPill()
        .padding(.bottom, 20)
        .padding(.top, 8)
        #else
        HStack(alignment: .bottom, spacing: 8) {
            attachButton
            textField
                .onAppear { focusProxy.setter = { focused = $0 } }
                .onDisappear { focusProxy.setter = nil }
            sendButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        #endif
    }

    // MARK: Attach

    @ViewBuilder
    private var attachButton: some View {
        PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
            Image(systemName: "paperclip")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                #if !targetEnvironment(macCatalyst)
                .modifier(GlassPill())
                #endif
        }
        .disabled(isUploading)
    }

    // MARK: Text field

    @ViewBuilder
    private var textField: some View {
        let placeholder: String = {
            switch mode {
            case .message: return "Message"
            case .editing: return "Edit message"
            case .replying: return "Reply…"
            }
        }()
        #if targetEnvironment(macCatalyst)
        // UITextField wrapper — SwiftUI's `focusEffectDisabled()`
        // doesn't suppress Catalyst's native focus ring, so we bridge
        // to UIKit and set `focusEffect = nil` directly.
        // Height pinned to the body line-height because UITextField's
        // intrinsic size doesn't propagate through UIViewRepresentable
        // and the capsule otherwise stretches to fill available space.
        CatalystPlainTextField(
            placeholder: placeholder,
            text: $draft,
            onSubmit: onSubmitMacCatalyst,
            focusProxy: focusProxy
        )
        .frame(height: 22)
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        #else
        TextField(placeholder, text: $draft, axis: .vertical)
            .focused($focused)
            .lineLimit(1...5)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(Color.clear)
            .modifier(GlassPill())
        #endif
    }

    // MARK: Send

    @ViewBuilder
    private var sendButton: some View {
        Button(action: onSend) {
            Group {
                if isUploading {
                    ProgressView().tint(theme.sendGlyph)
                } else {
                    Image(systemName: sendGlyph)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.sendGlyph)
                }
            }
            .frame(width: 44, height: 44)
            .background(
                Circle().fill(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? theme.sendDisabledBg
                        : theme.sendBg
                )
            )
        }
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isUploading)
    }

    private var sendGlyph: String {
        switch mode {
        case .editing: return "checkmark"
        default: return "arrow.up"
        }
    }
}

#if targetEnvironment(macCatalyst)
/// `UITextField` wrapper used on Catalyst. SwiftUI's
/// `focusEffectDisabled()` doesn't suppress the native macOS focus
/// ring that appears around `UITextField` on Catalyst, so we bridge to
/// UIKit and set `focusEffect = nil` directly. Visual treatment
/// (background, padding, shape) is owned by the outer pill — this
/// field is transparent and unstyled.
struct CatalystPlainTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void
    let focusProxy: ChatInputView.FocusProxy

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.text = text
        tf.borderStyle = .none
        tf.backgroundColor = .clear
        tf.focusEffect = nil
        tf.returnKeyType = .send
        tf.font = UIFont.preferredFont(forTextStyle: .body)
        tf.delegate = context.coordinator
        tf.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )
        // Route the external focus proxy straight to first-responder
        // calls on this field. No SwiftUI `@FocusState` in the loop.
        focusProxy.setter = { [weak tf] focus in
            guard let tf else { return }
            if focus { tf.becomeFirstResponder() }
            else { tf.resignFirstResponder() }
        }
        context.coordinator.ownedFocusProxy = focusProxy
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        if tf.text != text { tf.text = text }
        if tf.placeholder != placeholder { tf.placeholder = placeholder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CatalystPlainTextField
        weak var ownedFocusProxy: ChatInputView.FocusProxy?

        init(_ parent: CatalystPlainTextField) { self.parent = parent }

        deinit { ownedFocusProxy?.setter = nil }

        @objc func textChanged(_ tf: UITextField) {
            parent.text = tf.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }
    }
}
#endif
