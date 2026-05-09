# Topics — 3-column collapse layout (Spec A.1 of #112)

**Date:** 2026-05-07
**Author:** nakamoto-hiru — drafted via `superpowers:brainstorming`
**Status:** Awaiting review before plan/implementation
**Target branch:** continue on `hiru-topics-rework-entry` (PR #118 still draft)
**Builds on:** Spec A — `docs/superpowers/specs/2026-05-06-topics-entry-navigation-rework-design.md`

---

## 0. Why this spec exists

Spec A shipped Telegram-Forum-style sidebar swap on Catalyst — clicking a topic-enabled group replaces the chats list with the topic list. While correct, this hides the chats list entirely, costing context: user can't see other ongoing chats (DM / non-topic groups / sibling forums) without backing out.

This spec adds the Telegram **Desktop**-style "compact column" pattern: when in topic mode, the chats list collapses into a narrow icon-only column on the left, and the topic list becomes the second column. The chat detail remains in the third column.

Result: 2-column → 3-column transition on entry to topic mode, 3-column → 2-column on exit.

---

## 1. Behavior

### 1.1 Layout states

**Normal mode (no topic active):**
```
[ NavigationSplitView sidebar (chats list) │ detail (chat) ]
        280-320pt                                 rest
```

**Topic mode (after `enterTopicMode`):**
```
[ icon col │ topic list │ detail (topic chat) ]
   56pt       230-264pt          rest
```

Total left-area width on Catalyst stays inside the existing `applyMacSidebarWidth` range (min 280, ideal 320, max 420). The icon column is rendered **inside** the pushed `navigationDestination`, not by adding a third column to the `NavigationSplitView`.

### 1.2 Icon column content

- Lists **all conversations** (DMs + groups + forum groups), in the same sort order as `ConversationsListView`.
- Each row: 32pt avatar (circle) + optional unread chip below.
- Active row (whose `id == route.parent.id`) has a subtle accent BG `Color("AccentColor").opacity(0.15)` and rounded corners.
- Independent vertical scroll.

### 1.3 Tap behavior on icon row (smart switch)

- **Tapped icon's conversation has `hasTopicsEnabled == true`** (forum group):
  - If it's the **same** as current `route.parent` → no-op.
  - Else → reset `topicSidebarPath` to a fresh single-element path with the new group, and call `enterTopicMode(parent: newGroup)` so detail panel switches to its General topic. The icon column auto-rerenders the new active highlight.
- **Tapped icon's conversation is a DM or non-topic group**:
  - Call `router.exitTopicMode()` (clears `topicSidebarPath` and `selectedTopic`) → sidebar pops back to the chats list.
  - Set `router.selectedConversation = conversation` so the detail panel renders that chat.
  - Layout collapses 3-col → 2-col automatically because `topicSidebarPath` is empty.

This matches Telegram Desktop's natural "browse" behavior: forum-to-forum stays in compact mode, forum-to-DM exits compact mode.

### 1.4 iOS unaffected

Spec A.1 is **Catalyst-only**. iOS push navigation already gives the user back-button access to the chats list — no compact column needed.

---

## 2. Architecture & components

### 2.1 New file

**`GitchatIOS/Features/Conversations/Topics/IconChatsColumn.swift`** (Catalyst-only, gated `#if targetEnvironment(macCatalyst)`)
- Owns its own `@StateObject vm = ConversationsViewModel()` (acceptable v1 — `ConversationsCache` deduplicates the underlying fetch; the second instance hits cache after the chats-list instance has loaded).
- Renders a `ScrollView(.vertical) { LazyVStack { ForEach(...) { row } } }`.
- Each row is a tappable avatar with optional unread chip.
- Avatar reuses the existing `AvatarView` (defined in `ConversationsListView.swift:1287`) at 32pt, falling back to the conversation's initial letter.
- Tap handler implements the smart-switch logic from §1.3.

### 2.2 Modified file

**`GitchatIOS/Core/UI/MacShellView.swift`** — wrap the pushed `TopicListSidebarView` in an `HStack` with the icon column:

```swift
.navigationDestination(for: TopicSidebarRoute.self) { route in
    HStack(spacing: 0) {
        IconChatsColumn(activeParentId: route.parent.id)
            .frame(width: 56)
        Divider()
        TopicListSidebarView(parent: route.parent)
    }
}
```

### 2.3 Smart-switch helper on AppRouter

Add a new method to `AppRouter` to keep the routing decision in one place:

```swift
/// Picks a chats-list conversation while the user is in topic mode.
/// Forum groups swap topic list; non-forum chats exit topic mode.
func switchToConversation(_ convo: Conversation) {
    if convo.hasTopicsEnabled {
        // Replace path with a fresh single-element route, no stacking.
        topicSidebarPath = NavigationPath()
        enterTopicMode(parent: convo)
    } else {
        exitTopicMode()
        selectedConversation = convo
    }
}
```

`IconChatsColumn` calls `router.switchToConversation(convo)` from its row tap handler.

---

## 3. Visual spec

### 3.1 Icon row

```
┌──────────────────┐
│      ●●●         │   <- 32pt avatar, centered horizontally
│       ⓿          │   <- unread chip (8pt below avatar, only if unread > 0)
└──────────────────┘
   56pt total width, ~52pt row height
```

- Avatar: 32×32, full circle (NOT rounded square — matches `ConversationRow`'s `AvatarView`).
- Unread chip: same `Color("AccentColor")` capsule as `ConversationRow`, rendered below the avatar (not as a corner badge — clearer at small size).
- Active highlight: row background `Color("AccentColor").opacity(0.15)`, 8pt corner radius, 4pt horizontal inset.
- Hover: `.macHover()` modifier.

### 3.2 Layout dimensions

- Icon column width: **56pt** (32pt avatar + 12pt horizontal padding each side).
- Vertical padding per row: 6pt top/bottom.
- Inter-row spacing: 0pt (rows touch — visual rhythm comes from row padding).
- Divider between icon column and topic list: 1pt vertical, system separator color.

### 3.3 Sidebar width policy

No change to `applyMacSidebarWidth`. The total compact column footprint is `56 + 1 + 230 = 287pt`, comfortably inside the existing min 280 / ideal 320 range. The topic list squeezes from ~280pt to ~230pt — text already truncates with `lineLimit(1)`, so the change is graceful.

---

## 4. Animations

| Moment | Implementation |
|--------|----------------|
| Enter topic mode (sidebar swap to 3-col) | `NavigationStack` default push transition. The `HStack(iconCol + topicList)` slides in as a single unit because it's the destination view. |
| Exit topic mode | NavigationStack default pop. |
| Icon row tap → switch forum group | Existing `.transition(.opacity.combined(with: .move(edge: .trailing)))` on detail panel `Group` fires (since `selectedTopic` changes). Icon column's active highlight animates via `.animation(.easeInOut(duration: 0.18), value: activeParentId)`. |
| Icon row press feedback | Same `simultaneousGesture(DragGesture(minimumDistance: 0))` + `scaleEffect(0.95)` pattern as `TopicRow` (smaller scale because the row is smaller). |
| Hover (Catalyst) | `.macHover()` |

No new spring tunings introduced.

---

## 5. Data flow

- `IconChatsColumn` owns its own `ConversationsViewModel` instance. The underlying `ConversationsCache` (existing) deduplicates the network round-trips, so the cost is one extra observable wrapper, not double fetches.
- `activeParentId: String` is passed as a parameter from `MacShellView`'s `navigationDestination` (= `route.parent.id`).
- Tap handler calls `AppRouter.shared.switchToConversation(_:)`.
- `router.topicSidebarPath` is reassigned (not appended) when switching forum-to-forum, ensuring single-element invariant per the doc-comment in `AppRouter.swift:80`.

### 5.1 Edge cases

- **Same-group icon tap**: `switchToConversation` early-outs before mutating any state if `convo.id == router.selectedTopic?.parent.id`. Prevents flicker.
- **Forum group with no topics yet** (admin just enabled): `enterTopicMode` resolves no topic → `selectedTopic = nil` → detail panel shows the placeholder. Icon column still highlights the active row (because `route.parent.id` is set).
- **Conversations list still loading when user taps icon**: tap is no-op until `vm.conversations` populates. Rows that haven't loaded simply don't render. No spinner per icon — the empty space is the affordance.
- **Conversation becomes archived/deleted while user is browsing**: existing `vm` filtering handles removal — its row vanishes. If the now-active topic-mode parent is the one removed, `MacShellView`'s archived-detection (Spec A §5.5) fires and exits topic mode.

---

## 6. Verification

### 6.1 Compile gates
Same as Spec A — `xcodebuild` for both iOS Simulator (regression check) and Mac Catalyst (target).

### 6.2 Manual scenarios

| # | Scenario | Pass criteria |
|---|----------|---------------|
| 1 | Click forum group from chats list | Sidebar pushes 3-col layout: icon col + topic list + detail = General |
| 2 | In 3-col, click another forum group icon | Topic list swaps to new parent's topics, detail panel re-renders |
| 3 | In 3-col, click a DM icon | Layout collapses to 2-col, DM chat opens in detail |
| 4 | In 3-col, click the active group's own icon | No-op (no flicker, detail panel does not rebuild) |
| 5 | In 3-col, scroll icon column | Independent of topic list scroll |
| 6 | Hover an icon | macHover effect (subtle background) |
| 7 | Click "‹ Back" in topic list header | 3-col → 2-col, back to chats list |
| 8 | Active row highlight | Current parent's icon has accent BG |
| 9 | Unread badges | Visible on icons that have unread |
| 10 | iOS regression | Spec A iOS flow unchanged |

### 6.3 No backend changes
This is pure UI composition. Same APIs (`fetchConversations`, etc.) used by `ConversationsViewModel`.

---

## 7. Risks & open questions

### 7.1 Risks

- **Double `ConversationsViewModel`**: Spec accepts the trade-off (cache absorbs the cost). If profiling shows this is expensive, lift VM to MacShellView and inject — straightforward refactor.
- **Topic list squeezed to ~230pt**: visual check needed. If Hieu finds names truncate too aggressively, bump `applyMacSidebarWidth` ideal from 320 → 360.
- **Smart-switch on forum groups uses `topicSidebarPath = NavigationPath()` to reset before re-pushing**: this is correct semantically but causes a 1-frame flash where the sidebar path is empty. SwiftUI handles this in a single update cycle, so usually invisible. If observed, batch into `withAnimation` block.

### 7.2 Open questions deferred to implementation

- Whether `IconChatsColumn` should support drag-and-drop reordering of pinned chats (current chats list does — see `ConversationsListView`'s swipe actions). v1 says no — icon column is read-only-ish, full row interactions stay in chats list.
- Right-click context menu on icon (mute, mark read, archive)? v1 says no — icon column tap-only. Long-press peek can be added later if requested.

---

## 8. Out of scope (this spec)

- Animation of the column itself sliding in/out as a separate motion (currently rides the NavigationStack's default push)
- Custom hover preview / peek of conversation content
- Filtering / search inside icon column
- iOS adaptation
