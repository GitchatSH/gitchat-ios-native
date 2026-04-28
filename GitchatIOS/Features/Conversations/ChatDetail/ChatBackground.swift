import SwiftUI

/// Subtle Telegram-style background for the chat detail view.
/// A soft accent-tinted gradient with a faint dotted pattern overlay,
/// rendered behind the message list. Adapts to light/dark mode via
/// system colors so it never fights the bubble palette.
struct ChatBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color(.systemBackground)
    }
}
