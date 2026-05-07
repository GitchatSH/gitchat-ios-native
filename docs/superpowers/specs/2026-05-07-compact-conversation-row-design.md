# Compact ConversationRow — Telegram-style avatar-only collapse

**Date:** 2026-05-07
**Branch:** `hiru-topics-rework-entry`
**Touches:** `GitchatIOS/Features/Conversations/ConversationsListView.swift`

## Problem

When the user enters topic mode (taps a chat with topics), `MacShellView` passes
`compact: true` to `ConversationsListView`, which propagates to each
`ConversationRow`. Today the row still renders its full
`regularBody` (avatar + 2-line text VStack), and the call site clamps the
result to a 60pt frame with `.clipped()` (`ConversationsListView.swift:534-535`).

The visible artifact: title and preview text get sliced mid-glyph at the
60pt edge, leaking into the topic-list column with a ragged right edge
(see screenshot 2026-05-07 from Hiếu).

A previous attempt (`cfb183b revert: back to compactBody approach`)
introduced a `compactBody` view but was reverted — it broke tap
targets. The current "clip the same regularBody" workaround
(`8057884 fix(ios): 3-column collapse — clip same regularBody to 60pt`)
preserves clicks but creates the visual mess.

## Goal

In compact mode, render only what should be visible — avatar + halo for
the active row + unread badge — instead of clipping a full row.
Match the Telegram pattern Hiếu referenced.

## Design

### Render tree

`ConversationRow.body` switches on `compact`:

```swift
var body: some View {
    if compact { compactBody } else { regularBody }
}
```

### `compactBody`

A single avatar centered in a 60pt-wide cell:

- **Avatar:** the same `GroupAvatarView` / `AvatarView` used in
  `regularBody`, with the existing `avatarSize` (44pt on Catalyst —
  this view is Catalyst-only in practice; the iOS push pattern doesn't
  enter compact mode).
- **Halo for active row:** `Circle().stroke(Color("AccentColor"), lineWidth: 2)`
  overlaid on the avatar with ~3pt gap (use `.padding(-3)` on the
  stroke, or a `frame(width: avatarSize + 6, height: avatarSize + 6)`
  containing the stroke). Only renders when `isActive == true`.
- **Unread badge:** a small pill with `displayedUnread`, anchored to
  bottom-right of the avatar via `.overlay(alignment: .bottomTrailing)`.
  Telegram-style colors:
  - Default unread: `Color(.systemGray)`
  - Mention (`hasMention`): `Color("AccentColor")`
  - Muted (`isMuted`): `Color(.systemGray3)`
  - Border: 2pt stroke matching sidebar background
    (`Color(.systemBackground)` or whatever the sidebar resolves to)
    so the pill appears to "punch out" of the avatar.
  - Hidden when `displayedUnread == 0`.
- **Cell layout:** wrap in a centered container that fills the 60pt
  cell so the entire 60×N area is tappable:

  ```swift
  private var compactBody: some View {
      avatar
          .overlay(alignment: .center) { if isActive { halo } }
          .overlay(alignment: .bottomTrailing) { if displayedUnread > 0 { badge } }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.vertical, 8)
  }
  ```

### Call-site change (`conversationListRow`, line 524-540)

```swift
ConversationRow(...)
    .transaction { $0.animation = nil }
    .frame(maxWidth: compact ? 60 : .infinity, alignment: compact ? .center : .leading)
    .contentShape(Rectangle())   // covers the full 60pt cell
    .background(...)
    ...
```

Remove `.clipped()` — `compactBody` no longer overflows. Switch
alignment to `.center` in compact mode so the avatar sits in the
middle of the column. The fixed-width frame + `contentShape` is what
fixes the previous tap-target regression: the tappable rectangle now
matches the cell exactly.

### Why this fixes the previous click breakage

Last attempt's `compactBody` had a natural width of ~44pt (just the
avatar). When wrapped in `.frame(maxWidth: 60, alignment: .leading)`,
SwiftUI sized the row to the natural avatar width and left a ~16pt
non-tappable gap on the right. By making `compactBody` itself fill
`maxWidth: .infinity`, the rendered frame matches the 60pt outer
constraint exactly, and `contentShape(Rectangle())` covers it cleanly.

### Out of scope

- No hover tooltip showing the chat name (could come later).
- No animation between `regularBody` ↔ `compactBody` — keep the
  existing `.transaction { $0.animation = nil }` so morphs are instant
  and hit-testing doesn't get a chance to drift mid-animation.
- No change to `regularBody`, `ConversationsListView.sidebar`,
  `catalystSidebar` GeometryReader split, or `TopicListSidebarView`.
- No change to `MacShellView` — it already passes `compact:
  router.activeForumParent != nil`.
- iOS (non-Catalyst) is unaffected; topic mode there uses
  `NavigationStack.path` push, never sets `compact = true`.

## Verification

Per `CLAUDE.md`: no XCTest target. Verification is `xcodebuild` +
manual scenarios on a Catalyst run.

1. **Build:** `xcodebuild -scheme Gitchat -destination 'platform=macOS,variant=Mac Catalyst' build` succeeds.
2. **Manual — clean collapse:** Enter topic mode by clicking
   "Never Give Up". Confirm the chats column shows only avatars,
   no clipped text. The active row's avatar shows the orange halo.
3. **Manual — clicks work:** Tap a different avatar in the compact
   column. Confirm `router.switchToConversation(...)` fires
   (NSLog visible via `xcrun simctl spawn ... log stream`) and the
   layout switches to the new chat's topics — no missed taps.
4. **Manual — unread badge:** Find a chat with unread messages while
   in topic mode. Badge appears bottom-right of avatar with the count.
   Mute it via the regular row — badge turns gray.
5. **Manual — exit topic mode:** Tap a non-topic chat (DM). Confirm
   `router.exitTopicMode()` fires, sidebar expands back to full
   width, rows render `regularBody` again.

## Risks

- **3pt halo gap may clip:** if the sidebar background changes color
  per row (e.g. selection highlight on `regularBody`), the halo could
  look misaligned. In compact mode the row no longer has a per-row
  background — confirm with manual run.
- **Badge readability over dark avatars:** the 2pt sidebar-color border
  should provide enough contrast; if a row badge sits over a dark
  avatar in dark mode and the sidebar is also dark, the border may
  blend. Watch for this in dark-mode scenario.

## File-level changes

- `GitchatIOS/Features/Conversations/ConversationsListView.swift`
  - `ConversationRow.body` — switch on `compact`
  - Add `compactBody`, `haloOverlay`, `badgeOverlay` (or inline)
  - `conversationListRow(_:)` — drop `.clipped()`, switch alignment,
    keep `contentShape(Rectangle())`
