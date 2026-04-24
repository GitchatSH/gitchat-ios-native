import SwiftUI

/// Constants used to standardize sidebar row layout on Mac Catalyst.
/// On iOS the original per-row defaults are preserved — these helpers
/// only kick in inside `#if targetEnvironment(macCatalyst)` overrides
/// or via the platform-aware properties below.
///
/// Values follow Apple HIG list cell defaults: 44pt avatar, body
/// emphasized title, secondary subtitle, footnote meta.

/// Avatar diameter for Catalyst sidebar rows. iOS rows pass their own
/// size unchanged (chat list keeps 50pt for the Telegram look, contact
/// rows keep 40pt).
var macRowAvatarSize: CGFloat {
    #if targetEnvironment(macCatalyst)
    return 44
    #else
    return 40
    #endif
}

/// Subtitle font for Catalyst sidebar rows. Matches HIG body secondary
/// (15pt) instead of caption (12pt) so the text is comfortably readable
/// at desktop viewing distance.
var macRowSubtitleFont: Font {
    #if targetEnvironment(macCatalyst)
    return .subheadline
    #else
    return .caption
    #endif
}

/// Meta font (timestamps, relative time labels) — `.footnote` (13pt)
/// on Catalyst, original `.caption2` (11pt) on iOS.
var macRowMetaFont: Font {
    #if targetEnvironment(macCatalyst)
    return .footnote
    #else
    return .caption2
    #endif
}

/// Title font — `.headline` (17pt semibold) everywhere. Defined here
/// so future tweaks land in one place.
var macRowTitleFont: Font { .headline }

/// Horizontal padding INSIDE each row. 16pt — provides the column
/// inset directly (since `macRowListContainer()` strips the List's
/// own horizontal margins on Catalyst). Generous inside-padding gives
/// the active accent-color background room to breathe around content.
let macRowHorizontalPadding: CGFloat = 16

/// Vertical padding inside each row. Matches Apple Mail row rhythm
/// (4pt subgrid, total row height ~68pt with a 44pt avatar).
let macRowVerticalPadding: CGFloat = 12

/// Leading inset for the list-row separator. Equals
/// `horizontalPadding + avatarSize + avatarTextGap` so dividers start
/// flush with the title text (Apple Mail / Messages pattern).
var macRowSeparatorLeadingInset: CGFloat {
    macRowHorizontalPadding + macRowAvatarSize + 12
}

extension View {
    /// Container modifier for sidebar Lists on Catalyst:
    /// 1. Hide top/bottom section separators (collide with search bar / pill nav)
    /// 2. Strip the List's default horizontal `contentMargins` so rows
    ///    can extend almost to the sidebar edge — letting the active-row
    ///    rounded background fill more of the column. Row content gets
    ///    its own inset via `macRowHorizontalPadding`.
    @ViewBuilder
    func macRowListContainer() -> some View {
        #if targetEnvironment(macCatalyst)
        if #available(iOS 17.0, *) {
            self
                .listSectionSeparator(.hidden)
                .contentMargins(.horizontal, 0, for: .scrollContent)
        } else {
            self.listSectionSeparator(.hidden)
        }
        #else
        self
        #endif
    }
}
