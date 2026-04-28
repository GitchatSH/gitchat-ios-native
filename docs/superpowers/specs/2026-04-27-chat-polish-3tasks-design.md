# Chat Polish: 3 Tasks Design Spec

## Overview

Three Telegram-style polish features for the chat detail screen:
1. Sticky floating avatar in group conversations
2. Multi-segment pinned banner indicator
3. In-place long-press menu positioning

---

## Task 1: Sticky Floating Avatar in Groups

### Behavior

When viewing a group conversation, the sender avatar (32pt circle) for each same-sender message group behaves as a "sticky float":

- **Default position:** Anchored at the last (newest) message in the sender group — the `showTail` position.
- **Scroll up:** Avatar detaches from its anchor and floats along the left edge of the viewport, staying vertically aligned with the visible portion of the sender group.
- **Upper bound:** When the first message of the sender group approaches the top of the avatar's position, the avatar pins to that message and scrolls away with it.
- **Scroll down:** Avatar floats back down with the viewport until it reaches its default anchor (last message), then re-pins.

### Y-Position Formula

**Important:** The UITableView is rotated 180 degrees. In table coordinate space, Y increases downward (toward visual top). `contentOffset.y = 0` corresponds to the visual bottom. All formulas below use **visual (screen) coordinates** after `convert(_:to: tableView.superview)`.

```
// Convert cell frames to the overlay container's coordinate space
let firstRect = tableView.convert(firstCell.frame, to: overlayContainer)
let lastRect  = tableView.convert(lastCell.frame, to: overlayContainer)

// Visual coordinates: firstRect.minY = visual top of group,
// lastRect.maxY = visual bottom of group
let groupTop    = firstRect.minY
let groupBottom = lastRect.maxY
let viewBottom  = overlayContainer.bounds.height - composerInset

avatarY = clamp(
    min: groupTop,
    value: viewBottom - avatarSize,
    max: groupBottom - avatarSize
)
```

Where:
- `groupTop` = visual top of the first message cell in the group (screen coords)
- `groupBottom` = visual bottom of the last message cell (screen coords)
- `viewBottom` = bottom of visible area minus composer overlay
- `avatarSize` = 32pt

### Sender Group Detection

Walk `indexPathsForVisibleRows` in order. For each real message row (skip synthetic rows: typing indicator, seen avatar, date pills, unread divider), extend the current group if same sender, otherwise close the group and start a new one. In the rotated table, the first indexPath in a group = visual bottom (newest), last = visual top (oldest).

### Implementation Strategy

**Approach: UIView overlay on tableView's superview (sibling container)**

The avatar overlay must NOT be a subview of the UITableView — table subviews scroll with content. Instead, overlays are added to a transparent UIView that sits as a **sibling** of the table, layered on top via the SwiftUI ZStack or by walking to `tableView.superview` and adding there.

1. **AvatarOverlayManager** — a helper class owned by the Coordinator that manages floating avatar UIImageViews.
2. **Overlay container:** A transparent UIView added as sibling above the table. The Coordinator holds a weak reference. Created in `makeUIView` or lazily in the first `scrollViewDidScroll`.
3. **Data:** For each visible sender group, track:
   - `senderLogin: String`
   - `firstCellFrame: CGRect` (converted to overlay container coords)
   - `lastCellFrame: CGRect` (converted to overlay container coords)
   - `avatarURL: String?`
4. **scrollViewDidScroll:** On every scroll tick, recalculate Y positions for all visible sender groups and update the overlay view frames. **Throttle:** Only recalculate when `indexPathsForVisibleRows` changes (cache previous set and short-circuit on match).
5. **Cell avatar removal:** When a sender group has a floating overlay, the cell's inline avatar column renders as `Color.clear` (existing behavior for non-tail messages). The tail message's avatar also becomes clear when the overlay is active.
6. **Lifecycle:** Overlays are created/destroyed as sender groups enter/leave the visible rect. Pool UIImageViews keyed by sender login for reuse.
7. **Image loading:** Use the existing `ImageCache.shared` (UIKit-level cache) to load avatar images into UIImageView. Fallback to GitHub URL pattern: `https://github.com/{login}.png`.
8. **Accessibility:** Each overlay UIImageView sets `isAccessibilityElement = true`, `accessibilityLabel = "@{login}"`, `accessibilityTraits = .button`.

### Edge Cases

- **Single message group:** Avatar stays fixed at that message (groupTop == groupBottom - cellHeight, so clamp range is tiny → avatar pins to message).
- **Multiple sender groups visible simultaneously:** Each has its own independent overlay.
- **Performance:** UIImageView overlays are lightweight. Throttled recalculation via visible-rows diffing avoids unnecessary work on every scroll tick.
- **Keyboard visible:** `composerInset` already accounts for keyboard height via the existing `bottomInset` tracking in the Coordinator.

### Files to Modify

- `ChatMessagesList.swift` — Coordinator: add AvatarOverlayManager, hook into scrollViewDidScroll
- `ChatMessageView.swift` — Always render `Color.clear` for avatar column in groups (overlay handles it)
- New: `AvatarOverlayManager.swift` — manages floating avatar UIViews

---

## Task 2: Multi-Segment Pinned Banner Indicator

### Behavior

The left-side indicator bar in the pinned message banner adapts to the number of pinned messages:

#### Case: 1 pin
- Single accent-colored bar, width 3pt, full indicator height.
- No interaction change needed.

#### Case: 2-3 pins
- 2 or 3 segment bars, evenly divided within the total indicator height.
- 2pt gap between segments.
- **Active segment:** AccentColor solid.
- **Subtle segments:** AccentColor at 20% opacity.
- Tap cycles to next pin — active highlight animates to next segment + content crossfades.

#### Case: 4+ pins
- Always renders exactly 3 segment bars.
- Active segment position follows a "center-biased" rule:
  - `currentIndex == 0` → active at **top** (position 0)
  - `currentIndex == count - 1` → active at **bottom** (position 2)
  - All other indices → active at **middle** (position 1)
- Tap → bars slide vertically to maintain active-in-center + highlight animate.
- Animation: spring, response ~0.25s, damping ~0.7.

### Indicator Position Computation

```swift
func indicatorPosition(currentIndex: Int, totalCount: Int) -> Int {
    if totalCount <= 3 { return currentIndex }
    if currentIndex == 0 { return 0 }
    if currentIndex == totalCount - 1 { return 2 }
    return 1
}
```

### Animation Details

- **Segment transition:** `withAnimation(.spring(response: 0.25, dampingFraction: 0.7))`
- **Content crossfade:** Existing `easeInOut(duration: 0.15)` on the text/preview.
- **Slide direction:** When active moves from position 1→1 (middle stays middle but index changes), the bars themselves don't move — only the content changes. This creates a "carousel in the middle" feel.

### View Structure

```
PinnedIndicatorBar(count:, activeIndex:)
├── VStack(spacing: 2)
│   ├── Segment 0: RoundedRectangle, accent or subtle
│   ├── Segment 1: RoundedRectangle, accent or subtle
│   └── Segment 2: RoundedRectangle, accent or subtle (if count >= 3)
```

### State Management

- `currentIndex` should be lifted to `@Binding` or use `.onChange(of: pinnedMessages.count)` to clamp:
  ```swift
  .onChange(of: pinnedMessages.count) { newCount in
      if currentIndex >= newCount { currentIndex = max(0, newCount - 1) }
  }
  ```
- This prevents out-of-bounds when pins are added/removed while banner is visible.

### Files to Modify

- `PinnedBannerView.swift` — Replace single bar with `PinnedIndicatorBar`, update cycling logic.
- New: `PinnedIndicatorBar.swift` — Extracted indicator component.

---

## Task 3: In-Place Long-Press Menu

### Behavior

When the user long-presses a message, the bubble stays at its original screen position. The reaction bar and action dropdown arrange around it based on available space.

### Layout Algorithm

Given `sourceFrame` (bubble rect in screen coordinates). **Keyboard-aware:** `effectiveBottom = screenHeight - safeAreaBottom - keyboardHeight`.

1. **Bubble position:** Render preview at exactly `sourceFrame.origin` with `sourceFrame.size`.
2. **Reactions bar:** Always above the bubble.
   - `reactionsY = sourceFrame.minY - reactionsHeight - 8`
3. **Dropdown actions:** Prefer below, fallback above.
   - `spaceBelow = effectiveBottom - sourceFrame.maxY`
   - `spaceAbove = sourceFrame.minY - safeAreaTop - reactionsHeight - 8`
   - If `spaceBelow >= dropdownHeight + 8` → place below: `dropdownY = sourceFrame.maxY + 8`
   - Else → place above reactions: dropdown above reactions bar

### Edge Case: Near Bottom

When `sourceFrame.maxY > screenHeight - safeAreaBottom - dropdownHeight - 16`:
- Push bubble up by minimum amount to fit dropdown below OR reactions+dropdown above.
- `adjustment = max(0, (sourceFrame.maxY + dropdownHeight + 16) - (screenHeight - safeAreaBottom))`
- Bubble renders at `sourceFrame.minY - adjustment`

### Edge Case: Near Top

When `sourceFrame.minY < safeAreaTop + reactionsHeight + 16`:
- Push bubble down by minimum amount to fit reactions bar above.
- `adjustment = max(0, (safeAreaTop + reactionsHeight + 16) - sourceFrame.minY)`
- Bubble renders at `sourceFrame.minY + adjustment`

### Edge Case: Very Tall Bubble

When bubble height > viewport * 0.6:
- Clip bubble preview to max 60% viewport height.
- Reactions at top of clipped preview.
- Dropdown below clipped preview.

### Animation

- **Backdrop:** Fade in `.ultraThinMaterial` + black 35% (unchanged).
- **Bubble:** No position animation. Subtle scale pulse: `1.0 → 1.02 → 1.0` over 0.3s.
- **Reactions bar:** Scale in from sender-side anchor (unchanged).
- **Dropdown:** Scale in from sender-side anchor (unchanged).
- **Dismiss:** Reverse — backdrop fade, reactions/dropdown scale out, bubble pulse back.

### Positioning Implementation

Replace the current `.position(x:y:)` center-based layout with `.offset()` from `.topLeading` anchor. **Note:** SwiftUI's `.position()` places the view's CENTER at the given point, not its top-left. Using `.offset()` from a `.topLeading`-aligned ZStack avoids this pitfall.

```swift
GeometryReader { geo in
    ZStack(alignment: .topLeading) {
        backdrop

        // Each element uses .offset from top-left origin
        bubblePreview
            .frame(width: bubbleW, height: bubbleH)
            .offset(x: bubbleX, y: bubbleY)

        reactionsBar
            .offset(x: reactionsX, y: reactionsY)

        dropdownActions
            .offset(x: dropdownX, y: dropdownY)
    }
}
```

All X/Y values are **top-left offsets**, not center points. This maps directly to the layout algorithm's computed coordinates.

### Scroll Dismissal

When the underlying table scrolls while the menu is open, dismiss the menu immediately (matching Telegram behavior). The Coordinator can post a notification or set a binding that the menu observes.

### Files to Modify

- `MessageMenu.swift` — Rewrite `content(in:)` with new positioning logic.
- No new files needed.

---

## Testing Checklist

### Task 1
- [ ] Avatar floats when scrolling through a multi-message sender group
- [ ] Avatar pins at first message boundary (scroll up)
- [ ] Avatar pins at last message boundary (scroll down)
- [ ] Multiple sender groups visible — each avatar independent
- [ ] Single-message groups — avatar stays fixed
- [ ] Performance: smooth 60fps scroll with overlays

### Task 2
- [ ] 1 pin: single bar, no change
- [ ] 2 pins: 2 segments, tap cycles with animation
- [ ] 3 pins: 3 segments, tap cycles with animation
- [ ] 4+ pins: 3 segments, center-biased active, slide animation
- [ ] First pin → active at top position
- [ ] Last pin → active at bottom position
- [ ] Middle pins → active at middle position

### Task 3
- [ ] Long-press mid-screen: bubble stays, reactions above, dropdown below
- [ ] Long-press near bottom: bubble pushes up minimally, elements fit
- [ ] Long-press near top: reactions still visible above bubble
- [ ] Very tall bubble: clipped, elements still accessible
- [ ] Outgoing message: aligned right
- [ ] Incoming message: aligned left
- [ ] Dismiss animation smooth
