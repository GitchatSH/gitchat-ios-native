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
/// mention suggestions) live in dedicated files in this folder and
/// are composed by the owning view.
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
    let onPasteImage: (UIImage) -> Void

    /// Controls the placeholder + send glyph semantics.
    enum Mode {
        case message
        case editing
        case replying
    }

    /// External bridge so the parent view can gate focus explicitly
    /// (e.g. after a Reply action completes). Mirrors the bubbleless
    /// `@FocusState.Binding` pattern without leaking focus state.
    let focusProxy: FocusProxy

    final class FocusProxy: ObservableObject {
        var setter: ((Bool) -> Void)?
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
        PasteableTextField(
            placeholder: placeholder,
            text: $draft,
            onSubmit: onSubmitMacCatalyst,
            onPasteImage: onPasteImage,
            focusProxy: focusProxy
        )
        .frame(minHeight: 22)
        .padding(.horizontal, catalystOrIOS(catalyst: 10, ios: 16))
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        #if !targetEnvironment(macCatalyst)
        .modifier(GlassPill())
        #endif
        .accessibilityIdentifier("composer")
    }

    private func catalystOrIOS<T>(catalyst: T, ios: T) -> T {
        #if targetEnvironment(macCatalyst)
        return catalyst
        #else
        return ios
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
