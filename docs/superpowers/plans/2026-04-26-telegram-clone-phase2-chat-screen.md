# Phase 2: Chat Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the chat screen (DM + Group) to match Telegram iOS UX while following the Design System (8pt grid, semantic fonts/colors, 44pt touch targets).

**Architecture:** Extend existing rotated UITableView (`ChatMessagesList`) architecture. Add 4 new files (BubbleShape, UnreadDividerRow, DatePillOverlay, PinnedBannerView). Extend existing files for reactions, jump buttons, scroll state. All values Design System compliant.

**Tech Stack:** SwiftUI, UIKit (UITableView via UIViewRepresentable), Socket.IO, AVFoundation (checkmark assets)

**Spec:** `docs/superpowers/specs/2026-04-25-telegram-clone-phase2-chat-screen.md`
**Design System:** `docs/design/DESIGN.md`

---

## Sprint 1: Bubble Foundation (40-48h)

### Task 1: Asset Catalog Setup

**Files:**
- Create: `GitchatIOS/Resources/Assets.xcassets/ChatBackground.colorset/Contents.json`
- Create: `GitchatIOS/Resources/Assets.xcassets/BubbleMetaOut.colorset/Contents.json`
- Create: `GitchatIOS/Resources/Assets.xcassets/SenderColor1.colorset/Contents.json` (through SenderColor7)
- Create: `GitchatIOS/Resources/Assets.xcassets/CheckmarkSent.imageset/` (pre-rendered SVG)
- Create: `GitchatIOS/Resources/Assets.xcassets/CheckmarkRead.imageset/` (pre-rendered SVG)

- [ ] **Step 1: Create ChatBackground color set**

Light: `#EFE7DD` (warm beige). Dark: `#1C1A17` (warm dark).

- [ ] **Step 2: Create BubbleMetaOut color set**

Both light + dark: `#FFFFFFB3` (white 70% opacity). For timestamp + checkmarks on outgoing bubbles.

- [ ] **Step 3: Create SenderColor1-7 color sets**

| Color Set | Light | Dark |
|-----------|-------|------|
| SenderColor1 | `#E67E22` | `#F0A050` |
| SenderColor2 | `#3498DB` | `#5DADE2` |
| SenderColor3 | `#9B59B6` | `#BB8FCE` |
| SenderColor4 | `#2ECC71` | `#58D68D` |
| SenderColor5 | `#E74C3C` | `#EC7063` |
| SenderColor6 | `#1ABC9C` | `#48C9B0` |
| SenderColor7 | `#F39C12` | `#F5B041` |

- [ ] **Step 4: Create checkmark SVG assets**

CheckmarkSent: single check 12×8pt, white. CheckmarkRead: double check 16×8pt, white. Both as PDF vector assets in asset catalog.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Resources/Assets.xcassets/
git commit -m "feat(phase2): add asset catalog colors and checkmark assets"
```

---

### Task 2: Bubble Sizing & Radius Update

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift`

- [ ] **Step 1: Update bubble corner radius from 18pt to 20pt**

Find all `cornerRadius: 18` references in ChatMessageView.swift and update to `20`. This includes the bubble clip shape (~line 321) and any overlay strokes.

- [ ] **Step 2: Update bubble background colors**

Replace outgoing bubble color with `Color("AccentColor")` (if not already). Replace incoming bubble color with `Color(.secondarySystemGroupedBackground)` for dark mode safety.

- [ ] **Step 3: Update bubble padding**

Update bubble padding to 8pt vertical, 12pt horizontal (grid-compliant). Find existing padding values (~line 278-322) and update.

- [ ] **Step 4: Update bubble max-width to responsive**

Replace any hardcoded max-width with:
```swift
private var bubbleMaxWidth: CGFloat {
    #if targetEnvironment(macCatalyst)
    return 560
    #else
    let screenWidth = UIScreen.main.bounds.width
    if UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory {
        return screenWidth * 0.85
    }
    return min(screenWidth * 0.75, 304)
    #endif
}
```

- [ ] **Step 5: Update chat background color**

In `ChatDetailView.swift`, find where the chat background is set and use `Color("ChatBackground")`.

- [ ] **Step 6: Update spacing between messages**

In `ChatMessagesList.swift`, update message spacing: same sender gap = 4pt, different sender gap = 8pt. These are controlled by the cell layout, likely via padding on the cell content.

- [ ] **Step 7: Build and verify no regressions**

Run: `xcodebuild build -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 16'`

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(phase2): update bubble sizing, radius 20pt, responsive width, DS colors"
```

---

### Task 3: BubbleShape — Tail Decoration

**Files:**
- Create: `GitchatIOS/Features/Conversations/ChatDetail/Message/BubbleShape.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift`

- [ ] **Step 1: Create BubbleShape.swift**

```swift
import SwiftUI

/// Decorative tail drawn as overlay/underlay on the bubble.
/// Content is still clipped by RoundedRectangle — tail is visual only.
struct BubbleTailShape: Shape {
    let isOutgoing: Bool

    // Cache last rect + path
    private static var cache: (CGRect, Bool, Path)?

    func path(in rect: CGRect) -> Path {
        if let (r, o, p) = Self.cache, r == rect, o == isOutgoing { return p }

        var path = Path()
        let tailWidth: CGFloat = 8
        let tailHeight: CGFloat = 8

        if isOutgoing {
            // Bottom-right tail
            let start = CGPoint(x: rect.maxX, y: rect.maxY - tailHeight)
            path.move(to: start)
            path.addCurve(
                to: CGPoint(x: rect.maxX + tailWidth, y: rect.maxY),
                control1: CGPoint(x: rect.maxX + 2, y: rect.maxY - 2),
                control2: CGPoint(x: rect.maxX + tailWidth, y: rect.maxY - 2)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        } else {
            // Bottom-left tail
            let start = CGPoint(x: rect.minX, y: rect.maxY - tailHeight)
            path.move(to: start)
            path.addCurve(
                to: CGPoint(x: rect.minX - tailWidth, y: rect.maxY),
                control1: CGPoint(x: rect.minX - 2, y: rect.maxY - 2),
                control2: CGPoint(x: rect.minX - tailWidth, y: rect.maxY - 2)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }

        Self.cache = (rect, isOutgoing, path)
        return path
    }
}
```

- [ ] **Step 2: Add showTail computed property to message rendering**

In `ChatMessagesList.swift` cell builder, compute `showTail` by checking if the next message has a different sender or doesn't exist. Pass it to `ChatMessageView`.

Add parameter to ChatMessageView:
```swift
let showTail: Bool
```

Logic in cell builder (around line 419-438):
```swift
let showTail: Bool = {
    guard idx + 1 < items.count else { return true }
    return items[idx + 1].sender != item.sender
}()
```

Note: in the rotated table, array order is reversed (newest first), so `idx + 1` is the OLDER message. `showTail` should be true when the NEWER message (idx - 1) has a different sender. Verify the array order.

- [ ] **Step 3: Render tail overlay on bubble**

In ChatMessageView, add the tail decoration BEHIND the bubble (underlay) when `showTail == true`:

```swift
.background(alignment: isMe ? .bottomTrailing : .bottomLeading) {
    if showTail {
        BubbleTailShape(isOutgoing: isMe)
            .fill(isMe ? Color("AccentColor") : Color(.secondarySystemGroupedBackground))
            .frame(width: 16, height: 8)
            .offset(x: isMe ? 6 : -6)
    }
}
```

Adjust the bottom corner radius of the bubble to 4pt when `showTail`:
```swift
.clipShape(RoundedRectangle(cornerRadius: showTail ? (isMe ? /* custom corners */ 20) : 20))
```

For custom per-corner radius, use `UnevenRoundedRectangle` (iOS 16.4+) or a custom Shape.

- [ ] **Step 4: Add feature flag**

In ChatTheme or a new file:
```swift
enum ChatTheme {
    static var useBubbleTails: Bool = true
}
```

- [ ] **Step 5: Build and verify tails render correctly**

Test: DM and Group, incoming and outgoing, single message and multi-message groups.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(phase2): add bubble tail decoration with BubbleShape"
```

---

### Task 4: Inline Timestamp + Checkmarks

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift`

This is the hardest layout task. Budget 12-14h.

- [ ] **Step 1: Measure timestamp width**

Create a helper to measure the width of the timestamp + checkmark block:

```swift
private func timestampBlockWidth(for message: Message) -> CGFloat {
    let timeStr = message.shortTime ?? ""
    let font = UIFont.preferredFont(forTextStyle: .caption1) // 12pt
    let timeWidth = (timeStr as NSString).size(withAttributes: [.font: font]).width
    let checkWidth: CGFloat = isMe ? (isRead ? 20 : 16) : 0 // 16pt read + 4pt gap, or 12pt sent + 4pt gap
    let totalPadding: CGFloat = 8 // leading gap before timestamp
    return timeWidth + checkWidth + totalPadding
}
```

- [ ] **Step 2: Add invisible spacer to message text**

Append non-breaking spaces to the message text to reserve room for the timestamp overlay:

```swift
private func textWithTimestampReservation(_ text: String, reservedWidth: CGFloat) -> String {
    let spaceWidth: CGFloat = 4.5 // approximate width of \u{00A0} at .body size
    let spacesNeeded = Int(ceil(reservedWidth / spaceWidth)) + 1
    return text + String(repeating: "\u{00A0}", count: spacesNeeded)
}
```

- [ ] **Step 3: Overlay timestamp + checkmarks at bottom-trailing**

Replace the current external timestamp display with an overlay inside the bubble:

```swift
.overlay(alignment: .bottomTrailing) {
    HStack(spacing: 2) {
        Text(message.shortTime ?? "")
            .font(.caption)
            .foregroundColor(isMe ? Color("BubbleMetaOut") : .secondary)

        if isMe, let _ = message.id, message.unsent_at == nil {
            if isRead {
                Image("CheckmarkRead")
                    .renderingMode(.template)
                    .foregroundColor(isMe ? Color("BubbleMetaOut") : .secondary)
            } else {
                Image("CheckmarkSent")
                    .renderingMode(.template)
                    .foregroundColor(isMe ? Color("BubbleMetaOut").opacity(0.7) : .secondary)
            }
        }
    }
    .padding(.trailing, 8)
    .padding(.bottom, 4)
}
```

- [ ] **Step 4: Compute isRead from readCursors**

Add a binding or environment value for `readCursors` to ChatMessageView. Compute:

```swift
var isRead: Bool {
    guard isMe, let createdAt = message.created_at else { return false }
    if let otherReadAt = otherReadAt, otherReadAt >= createdAt { return true }
    // Group: any non-me cursor >= createdAt
    for (login, readAt) in readCursors where login != myLogin {
        if readAt >= createdAt { return true }
    }
    return false
}
```

- [ ] **Step 5: Add spring animation for read transition**

```swift
.onChange(of: isRead) { _, newValue in
    if newValue {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            // Animation is implicit via the Image swap
        }
    }
}
```

- [ ] **Step 6: Remove old external timestamp toggle**

Remove or deprecate the `showTime` state and tap-to-toggle-timestamp behavior. Timestamps are now always visible inline.

- [ ] **Step 7: Build and test**

Test: outgoing with sent checkmark, outgoing with read checkmark, incoming (no checkmark), short messages, long messages, accessibility sizes.

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(phase2): inline timestamp + delivery checkmarks in bubble"
```

---

### Task 5: Sender Name + Color (Group)

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift`

- [ ] **Step 1: Create stable sender color hash function**

```swift
extension String {
    var senderColorIndex: Int {
        let hash = self.utf8.reduce(5381) { ($0 &<< 5) &+ $0 &+ Int($1) }
        return abs(hash) % 7
    }

    var senderColor: Color {
        Color("SenderColor\(senderColorIndex + 1)")
    }
}
```

Add this in ChatMessageView or a shared extension file.

- [ ] **Step 2: Render sender name inside bubble (group incoming only)**

When `showHeader && !isMe && conversation.isGroup`:

```swift
// Inside bubble VStack, BEFORE message text
if showHeader && !isMe && conversation.isGroup {
    Text(message.sender)
        .font(.footnote.weight(.semibold))
        .foregroundColor(message.sender.senderColor)
}
```

- [ ] **Step 3: Update 2-column group layout**

Update avatar column width from 28pt to 32pt. Update gap from current to 8pt.

Show avatar on `showTail` (last message in group) instead of `showHeader` (first):
```swift
// Avatar visible only on tail (last in sender group)
if showTail {
    AvatarView(url: resolvedAvatar, size: 32)
} else {
    Color.clear.frame(width: 32, height: 32)
}
```

- [ ] **Step 4: Cache sender color computation**

Store computed colors in a static dictionary to avoid recomputation in view body:
```swift
private static var senderColorCache: [String: Color] = [:]
```

- [ ] **Step 5: Build and test**

Test: Group chat with multiple senders, verify colors are consistent across app launches, verify avatar shows on last message in group.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(phase2): sender name with stable hash colors inside group bubbles"
```

---

## Sprint 2: Scroll & Navigation (36-40h)

### Task 6: ChatScrollState + Date Pill

**Files:**
- Create: `GitchatIOS/Features/Conversations/ChatDetail/DatePillOverlay.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift`

- [ ] **Step 1: Create ChatScrollState**

Add to ChatMessagesList or a new section within it:

```swift
class ChatScrollState: ObservableObject {
    @Published var isAtBottom: Bool = true
    @Published var firstVisibleDate: Date?
    @Published var distanceFromBottom: CGFloat = 0
}
```

Replace the existing `isAtBottom: Binding<Bool>` with `ChatScrollState` object.

- [ ] **Step 2: Update scrollViewDidScroll to publish firstVisibleDate**

In Coordinator's `scrollViewDidScroll` (~line 539), after the existing isAtBottom logic:

```swift
// Date pill: find oldest visible message's date
if let visiblePaths = tableView.indexPathsForVisibleRows,
   let lastPath = visiblePaths.last, // oldest visible in rotated table
   let item = itemForIndexPath(lastPath) {
    scrollState.firstVisibleDate = ISO8601DateFormatter().date(from: item.created_at ?? "")
}
```

- [ ] **Step 3: Create DatePillOverlay.swift**

```swift
import SwiftUI

struct DatePillOverlay: View {
    @ObservedObject var scrollState: ChatScrollState
    @State private var visible = false

    var body: some View {
        if let date = scrollState.firstVisibleDate {
            Text(date.chatDateLabel)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .modifier(GlassPill())
                .opacity(visible ? 1 : 0)
                .onChange(of: scrollState.firstVisibleDate) { _, _ in
                    withAnimation(.easeInOut(duration: 0.2)) { visible = true }
                    // Auto-hide after 1.5s of no scroll
                }
        }
    }
}

extension Date {
    var chatDateLabel: String {
        if Calendar.current.isDateInToday(self) { return "Hôm nay" }
        if Calendar.current.isDateInYesterday(self) { return "Hôm qua" }
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMMM"
        fmt.locale = Locale(identifier: "vi_VN")
        return fmt.string(from: self)
    }
}
```

- [ ] **Step 4: Add DatePillOverlay to ChatDetailView**

Overlay on top of the message list:

```swift
.overlay(alignment: .top) {
    DatePillOverlay(scrollState: scrollState)
        .padding(.top, 8)
}
```

- [ ] **Step 5: Remove old date row rendering from ChatMessagesList**

The existing date rows (ChatDateRowPrefix, ~line 484) can stay as section markers in the list but should be visually simplified since the floating pill now handles date display.

- [ ] **Step 6: Build and test**

Test: Scroll through messages from different days, verify date pill updates, verify it fades in/out.

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(phase2): ChatScrollState + floating date pill overlay with GlassPill"
```

---

### Task 7: Unread Divider

**Files:**
- Create: `GitchatIOS/Features/Conversations/ChatDetail/List/UnreadDividerRow.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift`

- [ ] **Step 1: Create UnreadDividerRow.swift**

```swift
import SwiftUI

struct UnreadDividerRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            line
            Text("\(count) tin chưa đọc")
                .font(.caption2.weight(.semibold))
                .foregroundColor(Color("AccentColor"))
            line
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
    }

    private var line: some View {
        Rectangle()
            .fill(Color("AccentColor").opacity(0.2))
            .frame(height: 1)
    }
}
```

- [ ] **Step 2: Add synthetic row ID**

In ChatMessagesList.swift, add:
```swift
let ChatUnreadDividerID = "__v2_unread__"
```

- [ ] **Step 3: Compute unread divider position**

In ChatViewModel, add:
```swift
var myReadAt: String? {
    guard let myLogin = AuthStore.shared.login else { return nil }
    return readCursors[myLogin]
}

var unreadCount: Int {
    guard let readAt = myReadAt else { return messages.count }
    return messages.filter { ($0.created_at ?? "") > readAt }.count
}
```

- [ ] **Step 4: Insert divider as synthetic row in snapshot**

In `apply(items:...)` method (~line 443), insert the unread divider ID at the correct position based on `myReadAt`.

- [ ] **Step 5: Auto-scroll to divider on first load**

Set `pendingJumpId = ChatUnreadDividerID` after initial load. Use `CATransaction.setCompletionBlock` after `applySnapshot` to ensure layout is complete before scrolling.

- [ ] **Step 6: Remove divider when user reaches bottom**

When `scrollState.isAtBottom` becomes true and unread divider is visible, remove it via `reconfigureItems` (not `deleteItems`) to avoid content offset jump.

- [ ] **Step 7: Build and test**

Test: Open chat with unread messages, verify divider appears, auto-scroll works, divider removes on reaching bottom. Test with 200+ unread.

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(phase2): unread divider with auto-scroll and safe removal"
```

---

### Task 8: Jump Button Stack

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/JumpToBottomButton.swift` → rename to `JumpButtonStack.swift`

- [ ] **Step 1: Rename and extend JumpToBottomButton**

Rename file to `JumpButtonStack.swift`. Create a stack of conditional buttons:

```swift
struct JumpButtonStack: View {
    @ObservedObject var scrollState: ChatScrollState
    let unreadCount: Int
    let mentionCount: Int
    let onJumpToBottom: () -> Void
    let onJumpToUnread: () -> Void
    let onJumpToMention: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if mentionCount > 0 {
                jumpButton(icon: .text("@"), badge: mentionCount, action: onJumpToMention)
            }
            // React button omitted for v1 — needs reaction tracking infrastructure
            if !scrollState.isAtBottom {
                jumpButton(icon: .chevron, badge: unreadCount, action: onJumpToBottom)
            }
        }
    }

    private func jumpButton(icon: JumpIcon, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.selection(); action() }) {
            // 32pt visible circle with icon
        }
        .frame(width: 44, height: 44) // 44pt touch target
        .overlay(alignment: .top) {
            if badge > 0 {
                badgeView(badge)
            }
        }
    }
}
```

- [ ] **Step 2: Add button background style**

Each button: `Color(.systemBackground)`, shadow `radius: 4, y: 2, opacity: 0.12`, circle 32pt.

- [ ] **Step 3: Compute mention count from messages**

Precompute `Set<String>` of message IDs containing `@myLogin` in ChatViewModel. Intersect with off-screen message IDs from ChatScrollState.

- [ ] **Step 4: Wire into ChatDetailView**

Replace existing `JumpToBottomButton` usage with `JumpButtonStack`.

- [ ] **Step 5: Build and test**

Test: Scroll up → buttons appear, scroll to bottom → disappear, mention badge shows correct count.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(phase2): jump button stack with unread + mention badges"
```

---

### Task 9: Seen Avatars (20pt)

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift`

- [ ] **Step 1: Update seen avatar size from current to 20pt**

Update the existing `ChatSeenRowID` rendering in ChatMessagesList (~line 403-417). Avatar size → 20pt, border → 1pt, overlap → -4pt.

- [ ] **Step 2: Make seen row tap area 44pt height**

```swift
.frame(height: 44)
.contentShape(Rectangle())
.onTapGesture { onSeenByTap() }
```

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(phase2): seen avatars 20pt with 44pt touch target"
```

---

### Task 10: Typing Indicator as Pseudo-Message

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift`

- [ ] **Step 1: Update typing indicator row rendering**

The typing indicator already exists as a synthetic row (`ChatTypingRowID`). Update its rendering:
- DM: dots-only bubble with `Color(.secondarySystemGroupedBackground)`, tail left, 4pt bottom-left radius
- Group: 32pt avatar + dots bubble + "alice đang nhập..." label (`.caption2`, `.secondary`)

- [ ] **Step 2: Ensure typing pushes content if at bottom**

When typing row appears and user `isAtBottom`, auto-scroll to keep latest content visible. This should already work since typing is inserted at section 0 row 0 (newest position).

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(phase2): typing indicator as pseudo-message with group avatar"
```

---

## Sprint 3: Polish & Interactions (24-32h)

### Task 11: Reaction Pills Rework

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatReactionsRow.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift`

- [ ] **Step 1: Move reactions OUTSIDE bubble tap gesture**

In ChatMessageView, restructure so `ChatReactionsRow` is NOT a child of the bubble's `.onTapGesture` view hierarchy. Place it in a separate VStack level.

- [ ] **Step 2: Update reaction pill style**

```swift
// Per pill:
.background(mine ? Color("AccentColor").opacity(0.08) : Color(.systemBackground))
.overlay(Capsule().stroke(mine ? Color("AccentColor") : Color(.separator), lineWidth: 1))
.clipShape(Capsule())
```

Padding: 4pt vertical, 8pt horizontal (grid-compliant).

- [ ] **Step 3: Add per-pill tap toggle**

Replace row-level onTap with per-pill `.highPriorityGesture`:

```swift
.highPriorityGesture(TapGesture().onEnded {
    onToggleReaction(reaction.emoji)
})
.onLongPressGesture {
    onMoreReactions()
}
```

- [ ] **Step 4: Add 44pt touch height**

```swift
.frame(minHeight: 28)
.contentShape(Rectangle())
```

- [ ] **Step 5: Update pill alignment**

Incoming DM: padding-left 12pt. Incoming Group: padding-left 40pt (32 avatar + 8 gap). Outgoing: trailing-aligned.

- [ ] **Step 6: Build and test**

Test: Tap pill to toggle, long-press for picker, verify no gesture conflict with bubble tap.

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(phase2): reaction pills with per-pill toggle and 44pt touch"
```

---

### Task 12: Pinned Banner

**Files:**
- Create: `GitchatIOS/Features/Conversations/ChatDetail/PinnedBannerView.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetailView.swift`

- [ ] **Step 1: Create PinnedBannerView.swift**

```swift
struct PinnedBannerView: View {
    let pinnedMessages: [Message]
    let onTap: (Message) -> Void
    let onDismiss: () -> Void
    @State private var currentIndex = 0

    var body: some View {
        if let msg = pinnedMessages[safe: currentIndex] {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundColor(Color("AccentColor"))

                VStack(alignment: .leading, spacing: 0) {
                    Text("Tin ghim")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Color("AccentColor"))
                    Text(msg.content)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(.systemBackground))
            .onTapGesture { onTap(msg) }
        }
    }
}
```

- [ ] **Step 2: Add to ChatDetailView**

Place between nav header and message list. Only show for groups with pinned messages. Persist dismiss state in UserDefaults per conversation.

- [ ] **Step 3: Load pinned messages**

ChatViewModel already has `loadPinned()` (~line 186). Use `vm.pinnedIds` to fetch full messages.

- [ ] **Step 4: Build and test**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(phase2): pinned message banner for groups"
```

---

### Task 13: Failed Send Retry

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift`

- [ ] **Step 1: Add fail icon to outgoing bubbles**

When `message.unsent_at != nil` or message has send error:

```swift
if message.unsent_at != nil {
    HStack(spacing: 4) {
        bubbleContent
            .opacity(0.6)

        Button(action: onRetry) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(Color(.systemRed))
                .font(.system(size: 16))
        }
        .frame(width: 44, height: 44)
    }
}
```

- [ ] **Step 2: Add retry action sheet**

On tap: show ActionSheet with "Gửi lại" and "Xóa".

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(phase2): failed send retry icon with action sheet"
```

---

### Task 14: System Messages + Online/Last Seen

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Message/ChatMessageView.swift`
- Modify: `GitchatIOS/Features/Conversations/ChatDetailView.swift`

- [ ] **Step 1: Style system messages**

For messages where `type != "user"`: centered, `.caption2`, `.secondary`, italic, 8pt vertical padding. No bubble, no avatar.

- [ ] **Step 2: Update nav header with online/last seen**

DM: Show "online" (`.systemGreen`) or "hoạt động X phút trước" (`.secondary`). Add green dot on avatar.
Group: Show "N thành viên, M online". Tap → MembersSheet.

Use existing `PresenceStore` data.

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(phase2): system message styling + online/last seen in header"
```

---

### Task 15: Integration Test + Polish

- [ ] **Step 1: Test all 14 features on iPhone simulator**
- [ ] **Step 2: Test on Catalyst (if available)**
- [ ] **Step 3: Test Dark Mode for all features**
- [ ] **Step 4: Test Dynamic Type at AX3 and AX5**
- [ ] **Step 5: Fix any regressions found**
- [ ] **Step 6: Final commit**

```bash
git commit -m "feat(phase2): integration polish and dark mode fixes"
```

---

## File Map Summary

| File | Action | Task |
|------|--------|------|
| `Assets.xcassets/` (9 color sets + 2 SVGs) | Create | Task 1 |
| `BubbleShape.swift` | Create | Task 3 |
| `UnreadDividerRow.swift` | Create | Task 7 |
| `DatePillOverlay.swift` | Create | Task 6 |
| `PinnedBannerView.swift` | Create | Task 12 |
| `ChatMessageView.swift` | Modify | Tasks 2,3,4,5,11,13,14 |
| `ChatMessagesList.swift` | Modify | Tasks 2,3,6,7,9,10 |
| `ChatViewModel.swift` | Modify | Tasks 7,8 |
| `ChatDetailView.swift` | Modify | Tasks 2,6,8,12,14 |
| `ChatReactionsRow.swift` | Modify | Task 11 |
| `JumpToBottomButton.swift` → `JumpButtonStack.swift` | Rename+Modify | Task 8 |
