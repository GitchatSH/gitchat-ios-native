import SwiftUI

/// Semantic color tokens for the chat screen. Components read colors
/// from `@Environment(\.chatTheme)` rather than hard-coding
/// `Color("AccentColor")` or `Color(.secondarySystemBackground)` calls,
/// so the chat can be rethemed in one place and the overlay / menu /
/// composer stay visually aligned with the bubbles.
///
/// Structurally modelled on exyte/chat's `ChatTheme` (MIT) — but with
/// only the tokens Gitchat actually uses (no unused image slots, no
/// user-type styles).
struct ChatTheme: Equatable {
    // MARK: Bubble surfaces
    var bubbleIncoming: Color = Color(.secondarySystemGroupedBackground)
    var bubbleOutgoing: Color = Color("AccentColor")
    var bubbleIncomingText: Color = Color(.label)
    var bubbleOutgoingText: Color = .white
    /// Timestamp + checkmark color inside outgoing bubbles.
    var bubbleMetaOut: Color = Color.white.opacity(0.7)
    /// Timestamp + checkmark color inside incoming bubbles.
    var bubbleMetaIn: Color = Color(.secondaryLabel)

    // MARK: Reply preview
    var replyAccent: Color = Color("AccentColor")
    var replyBackground: Color = Color(.tertiarySystemBackground)

    // MARK: Date section header
    var dateHeaderBg: Color = Color(.tertiarySystemBackground)
    var dateHeaderText: Color = Color(.secondaryLabel)

    // MARK: Menu overlay + reaction picker
    var menuSurface: Color = Color(.secondarySystemBackground)
    var menuDivider: Color = Color(.separator)
    var reactionPickerBg: Color = Color(.secondarySystemBackground)
    var reactionPickerSelectedBg: Color = Color("AccentColor").opacity(0.25)
    var menuBackdrop: Color = Color.black

    // MARK: Composer
    var composerSurface: Color = Color(.secondarySystemBackground)
    var composerPlaceholder: Color = Color(.placeholderText)
    var sendBg: Color = Color("AccentColor")
    var sendDisabledBg: Color = Color.gray.opacity(0.5)
    var sendGlyph: Color = .white

    // MARK: Banners
    var blockedBannerBg: Color = Color(.secondarySystemBackground)

    static let `default` = ChatTheme()
}

private struct ChatThemeKey: EnvironmentKey {
    static let defaultValue: ChatTheme = .default
}

extension EnvironmentValues {
    var chatTheme: ChatTheme {
        get { self[ChatThemeKey.self] }
        set { self[ChatThemeKey.self] = newValue }
    }
}
