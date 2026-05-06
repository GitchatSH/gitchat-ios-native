# Topics — Entry & Navigation Rework (Spec A of #112)

**Date:** 2026-05-06
**Author:** nakamoto-hiru — drafted via `superpowers:brainstorming`
**Status:** ⚠️ Awaiting review before plan/implementation
**Target branch:** TBD (suggestion: `hiru-topics-rework-entry`)
**Tracking issue:** [#112 — Topics UI polish — desktop and mobile](https://github.com/GitchatSH/gitchat-ios-native/issues/112)

---

## 0. Why this spec exists

Issue #112 calls out 6 areas of Topics polish (list, create sheet, tab strip, in-thread bubbles, desktop layout, animations). The 6 areas are independent enough that bundling them into one PR would explode review scope. This spec covers **Spec A — Entry & navigation only**: the 3 surfaces a user touches to reach or switch between topics.

**Surfaces in scope:**
1. iOS topic list (currently `TopicListSheet` — bottom sheet)
2. Catalyst topic list (currently `TopicListContent` rendered inside a popover)
3. Catalyst tab strip (`TopicTabsStrip` rendered above chat body)

**Surfaces out of scope** (separate sub-specs of #112):
- Topic creation sheet polish
- Message bubbles inside a topic thread
- Animation/transition polish that lives inside the chat body itself
- Empty/loading polish for thread interior

**Direction picked:** **Full UX rework**, not refinement. The current shape (popover + tab strip + bottom sheet) carries duplicate entry points on Catalyst and a "modal trap" on iOS. We replace it with a **Telegram Forum-style sidebar swap** that matches the philosophy already documented in `MacShellView.swift`:

> "the Telegram Desktop pattern — switching tabs changes the sidebar, never the chat being read."

---

## 1. Behavior — the new flow

### 1.1 Catalyst (Mac shell)

```
ConversationsListView (sidebar)
  ↓ user clicks group with hasTopicsEnabled == true
  ↓
NavigationStack inside sidebar pushes TopicListSidebarView
  ↓ default: detail panel auto-renders the General topic
  ↓
user clicks topic row → detail panel re-renders with that topic's chat
user clicks "‹ Back" in sidebar header → pops back to ConversationsListView
```

When the user clicks a group **without** topics enabled, behavior is unchanged: detail panel renders that group's chat directly.

### 1.2 iOS

```
ConversationsListView
  ↓ tap group with hasTopicsEnabled == true
  ↓
NavigationStack pushes TopicListPushView
  ↓
tap topic row → push ChatDetailView(.topic(t, parent))
  ↓ back chevron → pops to TopicListPushView
  ↓ back chevron → pops to ConversationsListView
```

Stack depth max 3. Matches Telegram iOS forum-group flow.

### 1.3 Killed surfaces

- `TopicTabsStrip` is removed entirely. The sidebar now serves the quick-switch role on Catalyst.
- The Catalyst topic popover (`TopicListPopover` if it exists) is removed — sidebar swap supersedes it. (Verify file existence during implementation; if absent, no deletion needed.)
- `TopicListSheet` (iOS bottom sheet) is removed — replaced by `TopicListPushView`.

---

## 2. Architecture & components

### 2.1 New files

**`GitchatIOS/Features/Conversations/Topics/TopicListSidebarView.swift`** (Catalyst-only, gated `#if targetEnvironment(macCatalyst)`)
- Wraps `TopicListContent` with the 2-line sidebar header.
- Header layout: `‹ back chevron · group emoji 24pt · group name · spacer · "+" button`. Subtitle row: `"N members · M online"` (subdued).
- Reads `PresenceStore.shared` to compute online count, identical to `ChatDetailTitleBar.subtitleInfo`.
- "+" button presents `TopicCreateSheet`.
- "‹" pops the sidebar `NavigationStack`.

**`GitchatIOS/Features/Conversations/Topics/TopicListPushView.swift`** (iOS)
- Wraps `TopicListContent` inside a `NavigationStack` view.
- `.toolbar` with custom 2-line title (group name + member subtitle, same logic as Catalyst header subtitle).
- Trailing toolbar item: "+" presenting `TopicCreateSheet`.
- Tap on a topic row pushes `ChatDetailView(target: .topic(topic, parent))`.

### 2.2 Modified files

**`TopicRow.swift`** — overhaul to twin of `ConversationRow`:
- Adopt platform-aware icon size: 44pt (Catalyst) / 64pt (iOS), via `#if targetEnvironment(macCatalyst)`.
- Drop the duplicate emoji prefix in title. Title becomes plain `topic.name`. Icon square already shows the emoji on the color background — no need to repeat.
- Sender:preview format on the second line: `"alice: meeting at 3pm"` (compose `last_sender_login` + `last_message_preview`).
- Active state on Catalyst: accent BG + `.white` primary text + `.white.opacity(0.85)` secondary text. Match `ConversationRow.primaryTextColor` / `secondaryTextColor` pattern.
- Pin icon removed from inline row. The "PINNED" section header carries that meaning.

**`TopicListContent.swift`** — minor:
- Empty state: replace standalone emoji with an SF Symbol rendered in accent gradient (`bubble.left.and.text.bubble.right.fill`, `.symbolRenderingMode(.hierarchical)`). Headline `"Start a topic"`. Body `"Topics keep group conversations organized by subject."`. CTA `"+ New Topic"` (`borderedProminent`).
- Wrap `togglePin(...)` call in `withAnimation(.spring(response: 0.4, dampingFraction: 0.7))` so rows reorder smoothly between Pinned and All sections.
- Section header for "PINNED" is suppressed when `pinned.isEmpty` (already current behavior — keep).

**`MacShellView.swift`** — `case 0` of `currentTabSidebar`:
- Wrap `ConversationsListView()` inside `NavigationStack(path: $router.topicSidebarPath)`.
- `.navigationDestination(for: TopicSidebarRoute.self)` renders `TopicListSidebarView(parent: route.parent)`.
- Define `TopicSidebarRoute: Hashable { let parent: Conversation }` near the file or in `AppRouter.swift`.

**`ConversationsListView.swift`** — the row tap handler:
- When the tapped conversation has `hasTopicsEnabled == true`:
  - On Catalyst: call `router.enterTopicMode(parent: convo)`. The helper handles both the path append and active-topic resolution.
  - On iOS: replace the existing `NavigationLink(value: convo)` with `NavigationLink(value: TopicSidebarRoute(parent: convo))` so tapping pushes `TopicListPushView`. iOS does not call `enterTopicMode` — the `NavigationStack` push is the source of truth.
- When `hasTopicsEnabled == false`: keep the existing behavior unchanged (sets `selectedConversation` on Catalyst, pushes `ChatDetailView` on iOS).

**`ChatDetailView.swift`**:
- Remove the `safeAreaInset(edge: .top)` block that hosts `TopicTabsStrip`.
- Remove the `#if targetEnvironment(macCatalyst)` import/usage of `TopicTabsStrip` from `chatShell`.

**`ChatDetailTitleBar.swift`** — topic-target branch:
- Catalyst: drop the `.onTapGesture` (sidebar already shows the topic list — title-bar tap is redundant). Keep the visual title (emoji + name + chevron + "in <group>" subtitle); chevron becomes purely decorative or can be removed.
- iOS: keep the tap, but rebind it to `dismiss()` so the user pops back from the topic chat to `TopicListPushView`. The chevron now signals "back to topic list", consistent with the down-chevron metaphor for "open switcher above this view".

**`AppRouter.swift`** — add topic-mode state:
```swift
@Published var topicSidebarPath: NavigationPath = NavigationPath()
@Published var selectedTopic: (topic: Topic, parent: Conversation)? = nil
private(set) var activeTopicByParent: [String: String] = [:]   // parent.id → topic.id

func enterTopicMode(parent: Conversation) {
    topicSidebarPath.append(TopicSidebarRoute(parent: parent))
    let resolved = resolveActiveTopic(parent: parent)
    if let t = resolved { selectedTopic = (t, parent) }
}

func pickTopic(_ topic: Topic, in parent: Conversation) {
    activeTopicByParent[parent.id] = topic.id
    selectedTopic = (topic, parent)
    selectedConversation = nil   // clear so detail renders topic chat
}

func exitTopicMode() {
    topicSidebarPath = NavigationPath()
    selectedTopic = nil
}

private func resolveActiveTopic(parent: Conversation) -> Topic? {
    let topics = TopicListStore.shared.topics(forParent: parent.id)
    if let id = activeTopicByParent[parent.id],
       let t = topics.first(where: { $0.id == id }) { return t }
    if let general = topics.first(where: { $0.is_general }) { return general }
    return topics.first   // edge case: General missing
}
```

### 2.3 Deleted files

- `GitchatIOS/Features/Conversations/Topics/TopicTabsStrip.swift`
- `GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift`

`TopicListPopover.swift` is referenced in the doc-comment of `TopicListContent.swift` but does not exist as a real file in the repo (verified via `find`). No deletion needed; only update the stale doc-comment.

After deletion, run `xcodegen generate` and `grep` for any remaining references.

---

## 3. Visual spec

### 3.1 TopicRow (twin of ConversationRow)

Layout (HStack 12pt spacing, vertical padding 8pt, min-height 60pt iOS / 56pt Catalyst):

```
┌─────────────────────────────────────────────────────────┐
│ [emoji square]   Bugs                      15m  @  12  │
│  44 / 64pt       bob: reproduced on iOS 17              │
└─────────────────────────────────────────────────────────┘
```

**Active state (Catalyst):**
- Background: `Color("AccentColor")`
- Primary text: `.white`
- Secondary text (preview, time): `.white.opacity(0.85)`
- Unread badge: `.white.opacity(0.25)` BG, `.white` text
- Mention badge "@": same `.white.opacity(0.25)` BG, `.white` "@" text

**Active state (iOS):**
- Active typically not applicable on iOS push view (no concurrent sticky chat). Skip.

### 3.2 Sidebar header (Catalyst)

```
┌─────────────────────────────────────────────────────────┐
│ ‹  ⚡  team                                          + │
│        12 members · 3 online                            │
├─────────────────────────────────────────────────────────┤
│  PINNED                                                 │
│  💬  General …                                          │
└─────────────────────────────────────────────────────────┘
```

- Row 1: `‹` (back, 14pt, accent color) · group emoji square 24pt 6pt-radius · group `displayTitle` (`.subheadline.weight(.semibold)`, `.lineLimit(1)`, truncating tail) · spacer · `+` (16pt, accent color, weight bold).
- Row 2: subtitle text (`.caption2`, `.secondary`), indented 36pt to align under group name. Logic identical to `ChatDetailTitleBar.subtitleInfo`.
- Row 1 height ≈ 36pt, row 2 ≈ 12pt + 4pt vertical padding. Total ≈ 56pt.

### 3.3 iOS push-view header

- `NavigationStack` with custom `.toolbar` `principal` placement: VStack of group name + subtitle (caption2 secondary).
- `.toolbar` `trailing`: "+" button bound to `TopicCreateSheet`.
- Standard system back chevron on the leading edge.

### 3.4 Section structure

Three-tier (matches current logic in `TopicListContent`):
1. General topic always renders first, in its own implicit group (no header).
2. "PINNED" section header — only when `pinned.isEmpty == false`.
3. "ALL TOPICS" section header — for every other topic, sorted by `last_message_at` descending.

Section header style: `.font(.caption.weight(.semibold))`, `.foregroundStyle(.secondary)`, padded 12pt horizontal / 6pt vertical, background `clear`. Use the existing `SectionSpacingModifier` (`ConversationsListView.swift:1642`) with a 4pt spacing value to match the rest of the app's list section rhythm on iOS 17+.

### 3.5 Empty state

```
       [SF Symbol gradient]
            48pt

         Start a topic

  Topics keep group conversations
  organized by subject.

       [+ New Topic]    (borderedProminent)
```

- Vertically centered in the available area.
- Symbol: `bubble.left.and.text.bubble.right.fill`, `.symbolRenderingMode(.hierarchical)`, `.foregroundStyle(Color("AccentColor"))`.
- Headline: `.font(.title3.weight(.semibold))`, `.primary`.
- Body: `.font(.subheadline)`, `.secondary`, max 2 lines, centered.
- CTA: `.buttonStyle(.borderedProminent)`, `.controlSize(.large)`.

---

## 4. Animations

| # | Moment | Implementation |
|---|--------|----------------|
| 1 | Sidebar swap chats ↔ topics (Catalyst) | `NavigationStack` default push transition. No custom curve. |
| 2 | Detail panel topic switch | Existing `.id(detailIdentity)` rebuild in `MacShellView` already triggers a view replacement. Wrap the detail content in `.transition(.opacity.combined(with: .move(edge: .trailing)))`. |
| 3 | Active row state | `.animation(.easeInOut(duration: 0.18), value: isActive)` applied to the row's background fill. |
| 4 | Tap haptic (iOS) | `Haptics.selection()` invoked inside the row's tap handler. Catalyst: no-op. |
| 5 | Row press visual | `@State private var isPressed = false` + `.scaleEffect(isPressed ? 0.98 : 1.0)` + `.animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)`. Bind via `DragGesture(minimumDistance: 0)` or a `ButtonStyle` wrapper. |
| 6 | Pin reorder | Wrap `store.togglePin(...)` callsite in `withAnimation(.spring(response: 0.4, dampingFraction: 0.7))` so the row animates between sections. |

Out of scope: empty-state appear, shimmer-to-real fade, sidebar group avatar morphing.

---

## 5. Data flow & state

### 5.1 Existing infrastructure (unchanged)

- `TopicListStore.shared` — singleton, in-memory `parent_id → [Topic]` map.
- `APIClient.fetchTopics`, `markTopicRead`, `archiveTopic` — unchanged.
- `store.togglePin(topicId:parentId:)` — local-only per-device (matches VS Code extension).
- Socket `gitchatTopicEvent` → `store.applyEvent(evt)` — realtime CRUD updates.

### 5.2 New router state (in `AppRouter.swift`)

- `topicSidebarPath: NavigationPath` — drives the Catalyst sidebar `NavigationStack`.
- `selectedTopic: (topic: Topic, parent: Conversation)?` — what the detail panel renders when in topic mode.
- `activeTopicByParent: [String: String]` — in-memory dict (no persistence) tracking last-picked topic per parent for the current session.

### 5.3 Active topic resolution (Catalyst)

When `enterTopicMode(parent:)` is called:
1. Push `TopicSidebarRoute(parent:)` onto `topicSidebarPath`.
2. Look up `activeTopicByParent[parent.id]` → use that topic if found in the store.
3. Else find topic where `is_general == true` → use it.
4. Else (no general — rare) → use the first topic in `store.topics(forParent:)`.
5. Set `router.selectedTopic` accordingly. Detail panel reads `selectedTopic` and renders `ChatDetailView(target: .topic(...))`.

### 5.4 Active topic resolution (iOS)

iOS uses natural `NavigationStack` semantics: a `NavigationLink` from `TopicListPushView` pushes `ChatDetailView(target: .topic(...))`. No `activeTopicByParent` dict needed — back navigation handles state.

### 5.5 Edge cases

- **Group topic-enabled but list empty:** `TopicListContent` renders the polished empty state. Detail panel shows `ContentUnavailableCompat(title: "No topic yet", systemImage: "bubble.left.and.text.bubble.right")` (Catalyst).
- **Group with `hasTopicsEnabled == false`:** click row → existing behavior, opens chat directly. Sidebar stack does not push. Guard at the `ConversationsListView` row tap handler.
- **General topic deleted (admin-only operation):** `resolveActiveTopic` falls through to `topics.first`. No crash.
- **Active topic archived in realtime by another user:** `store.applyEvent` already removes it from the store. Add a hook in `AppRouter` that observes `TopicListStore.shared.objectWillChange` and, after the change applies, checks whether `selectedTopic?.topic.id` is still present in `store.topics(forParent: selectedTopic.parent.id)`. If not, post `ToastCenter.shared.show(.info, "Topic archived")` and call `exitTopicMode()`. Place the observation in the view that owns the detail panel (`MacShellView` for Catalyst, the `ChatDetailView` host for iOS) via `.onReceive(TopicListStore.shared.objectWillChange) { ... }`.
- **Re-entering same group after exiting:** `activeTopicByParent[parent.id]` retains the last pick → user lands back where they were.
- **App relaunch:** `activeTopicByParent` is in-memory only — relaunch starts fresh and lands on General.

---

## 6. Verification

Project has no XCTest target (per `CLAUDE.md`). Verification = `xcodebuild` clean compile + manual scenarios on a booted simulator and on Mac Catalyst.

### 6.1 Compile gates

```bash
xcodegen generate

# iOS Simulator
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build | tail -20

# Mac Catalyst
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build | tail -20
```

Verify new files are wired into the Xcode project:
```bash
grep -c "TopicListSidebarView.swift" GitchatIOS.xcodeproj/project.pbxproj
grep -c "TopicListPushView.swift"    GitchatIOS.xcodeproj/project.pbxproj
```

Both must return `≥ 2` (file ref + build phase ref).

Verify deleted files are no longer referenced:
```bash
grep -c "TopicTabsStrip\|TopicListSheet" GitchatIOS.xcodeproj/project.pbxproj
```

Should return `0`.

### 6.2 Manual test scenarios

| # | Scenario | Pass criteria |
|---|----------|---------------|
| 1 | Catalyst: click a topic-enabled group in chats list | Sidebar pushes topic list with 2-line header; detail panel auto-renders General |
| 2 | Catalyst: click a different topic row in the sidebar | Detail panel re-renders with that topic's chat; previous active row loses accent BG, new one gains it (180ms ease) |
| 3 | Catalyst: click "‹ Back" in the sidebar header | Sidebar pops to chats list; detail panel resets to placeholder ("Pick a conversation…") |
| 4 | Catalyst: click "+" in the sidebar header | `TopicCreateSheet` presents; create succeeds → new row appears in list |
| 5 | Either platform: pin/unpin via context menu | Row reorders between PINNED and ALL TOPICS sections with a visible spring animation |
| 6 | iOS: tap a topic-enabled group | `TopicListPushView` pushes; 2-line title shows correctly |
| 7 | iOS: tap a topic row | `ChatDetailView(.topic)` pushes; back chevron pops to topics list |
| 8 | Either platform: click a non-topic group | Falls through to existing chat detail behavior — no swap, no push |
| 9 | Topic-enabled group with no topics yet | Polished empty state renders with SF Symbol gradient + CTA |
| 10 | Catalyst: visual check above chat body | Tab strip is gone — top of chat content has no chip row |
| 11 | Either platform: another member online status changes | Subtitle "N members · M online" updates live |
| 12 | Catalyst: active topic gets archived by another user (realtime) | Toast `"Topic archived"`; sidebar pops back to topics list (or chats list if list becomes empty) |

### 6.3 Logging during dev

Use `NSLog` (per project convention — no `print()`):
- `[TopicSidebar] enter parent=<id>` when `enterTopicMode` runs.
- `[TopicSidebar] pick topic=<id>` when `pickTopic` runs.
- `[TopicSidebar] exit` when `exitTopicMode` runs.

Stream:
```bash
xcrun simctl spawn <udid> log stream --process Gitchat
```

---

## 7. Risks & open questions

### 7.1 Risks

- **Sidebar `NavigationStack` interaction with Catalyst tab switches.** `MacShellView` swaps the sidebar's content based on `selectedTab`. If the user is in topic mode (sidebar pushed) and switches to Discover, the topic stack is silently torn down. On returning to Chats, do we land on chats list (path reset) or topic list (path persisted)? **Decision:** reset — topic-mode is transient within the Chats tab; switching tabs always returns to chats list. Implementation: clear `topicSidebarPath` when `selectedTab` changes away from 0.
- **`@Published` of `(Topic, Conversation)?` tuple** — SwiftUI prefers structs. Wrap in a `struct TopicTarget: Equatable { let topic: Topic; let parent: Conversation }` so the diff works.
- **Detail panel's `detailIdentity` keying.** Today it keys on `selectedConversation.id` and `selectedProfile`. Add `selectedTopic.topic.id` to the identity so picking a different topic forces the rebuild we rely on for animation #2.

### 7.2 Open questions deferred to implementation

- Exact `NavigationLink` API: value-based (`NavigationLink(value:)` + `.navigationDestination(for:)`) is preferred for Catalyst path-driven flow. iOS may use either form.
- Whether `TopicListPushView` and `TopicListSidebarView` can share a single underlying view via a `Header` ViewBuilder param. If structurally identical except for the header, fold them.

---

## 8. Out of scope (tracked in #112 as separate sub-specs)

- Topic creation sheet polish (Spec B)
- Message bubbles inside a topic thread (Spec C)
- Animation/transitions inside the chat body for topic threads (Spec C addendum)
- Persistent `activeTopicByParent` across app relaunches (only worth doing if user feedback confirms it's missed)
- Search within topic list (skipped — group topic counts are typically < 30, search is overkill)
- Topic list unread badge in chats list (the parent group row's badge already aggregates unreads)
