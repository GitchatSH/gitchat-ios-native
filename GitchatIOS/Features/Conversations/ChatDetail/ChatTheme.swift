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
    var bubbleIncoming: Color = Color(.secondarySystemBackground)
    var bubbleOutgoing: Color = Color("AccentColor")
    var bubbleIncomingText: Color = Color(.label)
    var bubbleOutgoingText: Color = .white

    // Reply preview
    var replyAccent: Color = Color("AccentColor")
    var replyBackground: Color = Color(.tertiarySystemBackground)

    // Date section header
    var dateHeaderBg: Color = Color(.tertiarySystemBackground)
    var dateHeaderText: Color = Color(.secondaryLabel)

    // Menu + overlay
    var menuSurface: Color = Color(.secondarySystemBackground)
    var menuDivider: Color = Color(.separator)
    var reactionPickerBg: Color = Color(.secondarySystemBackground)

    // Composer
    var composerSurface: Color = Color(.secondarySystemBackground)
    var composerPlaceholder: Color = Color(.placeholderText)
    var sendBg: Color = Color("AccentColor")
    var sendDisabledBg: Color = Color.gray.opacity(0.5)

    // Banners
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
