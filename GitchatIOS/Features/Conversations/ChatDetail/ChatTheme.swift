import SwiftUI

/// Semantic color tokens for the chat screen. Components should read
/// colors from `@Environment(\.chatTheme)` rather than hard-coding
/// `Color("AccentColor")` or `Color(.secondarySystemBackground)` calls,
/// so we can retheme chat in one place.
///
/// This commit introduces the abstraction; call-site migration happens
/// opportunistically in follow-up commits.
struct ChatTheme: Equatable {
    // Bubble surfaces
    var bubbleIncoming: Color
    var bubbleOutgoing: Color
    var bubbleIncomingText: Color
    var bubbleOutgoingText: Color

    // Reply preview
    var replyAccent: Color
    var replyBackground: Color

    // Date section header
    var dateHeaderBg: Color
    var dateHeaderText: Color

    // Menu + overlay
    var menuSurface: Color
    var menuDivider: Color
    var reactionPickerBg: Color

    // Composer
    var composerSurface: Color
    var composerPlaceholder: Color
    var sendBg: Color
    var sendDisabledBg: Color

    // Banners
    var blockedBannerBg: Color

    static let `default` = ChatTheme(
        bubbleIncoming: Color(.secondarySystemBackground),
        bubbleOutgoing: Color("AccentColor"),
        bubbleIncomingText: Color(.label),
        bubbleOutgoingText: .white,

        replyAccent: Color("AccentColor"),
        replyBackground: Color(.tertiarySystemBackground),

        dateHeaderBg: Color(.tertiarySystemBackground),
        dateHeaderText: Color(.secondaryLabel),

        menuSurface: Color(.secondarySystemBackground),
        menuDivider: Color(.separator),
        reactionPickerBg: Color(.secondarySystemBackground),

        composerSurface: Color(.secondarySystemBackground),
        composerPlaceholder: Color(.placeholderText),
        sendBg: Color("AccentColor"),
        sendDisabledBg: Color.gray.opacity(0.5),

        blockedBannerBg: Color(.secondarySystemBackground)
    )
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
