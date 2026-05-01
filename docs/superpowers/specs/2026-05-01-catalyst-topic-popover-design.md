# Catalyst Topic Popover — Design Spec

**Date:** 2026-05-01
**Author:** Vincent (driven brainstorm) — drafted via `superpowers:brainstorming`
**Status:** ⚠️ **Superseded** — pivoted same day to a Telegram-Desktop-style tabs strip after Vincent's manual test surfaced a pre-existing issue. The popover anchor target (`ChatDetailTitleBar` in the SwiftUI toolbar) is not actually rendered on Catalyst because `ChatDetailView` calls `.toolbar(.hidden, for: .navigationBar)` (`ChatDetailView.swift:288`) and `ChatView.chatHeader` returns `EmptyView()` on Catalyst (`ChatView.swift:323`). With no visible header to tap, the popover entry point was undiscoverable. Vincent also pointed out that the Telegram Desktop "topic tabs strip below the chat header" pattern (Image 4 — `Clawquest_OpenACP` chat) is a much better fit for a desktop layout. **The shipped implementation is the tabs strip** described below, not the popover. The original popover sections (§§ 2-6) are preserved as historical context but should be read as superseded.
**Target branch:** `vincent-feat-catalyst-topic-popover` off `main`
**Depends on:** [`2026-04-28-ios-topic-feature-design.md`](2026-04-28-ios-topic-feature-design.md) (mobile topic feature, shipped)

---

## 0. Pivot — 2026-05-01: Tabs Strip (the actually-shipped design)

### 0.1 What changed

**Pattern:** Telegram-Desktop-style horizontal scrollable strip of topic chips rendered immediately above the chat body on Mac Catalyst, mirroring Telegram's `[All] [Notifications] [Assistant] [...] [# General]` row under the chat title (Image 4 reference shared by Vincent).

**Why pivoted:**
1. The popover anchor target (`ChatDetailTitleBar` in the SwiftUI toolbar) does not render on Catalyst — the navigation bar is force-hidden, and the custom `chatHeader` is iOS-only. Popover was undiscoverable in actual testing.
2. Catalyst window real estate suits a fixed always-visible navigation strip better than a click-to-reveal popover. Eliminates a click and surfaces topic state at a glance.
3. Matches a familiar Telegram Desktop pattern Vincent explicitly pointed at.

**Decisions for the strip:**
| # | Question | Decision |
|---|---|---|
| 1 | Strip placement | `.safeAreaInset(edge: .top, spacing: 0)` on `ChatView` inside `ChatDetailView.chatShell`, gated `#if targetEnvironment(macCatalyst)` and only when `vm.conversation.hasTopicsEnabled && resolvedTarget` is `.topic`. |
| 2 | When to show the strip | Always, as long as topics are enabled — even with a single General topic. The trailing `+` button must always be reachable. |
| 3 | Active chip indicator | Background `Color("AccentColor").opacity(0.15)` + bold weight + accent-tinted label. No underline. |
| 4 | Strip background | `Color(.secondarySystemBackground)` with a bottom `Divider()` separating it from the chat body. Distinct from the chat scroll area. |
| 5 | Topic ordering | General first, then locally pinned, then by `last_message_at` desc. Mirrors `TopicListContent` behaviour. |
| 6 | Unread display | Compact pill `Color("AccentColor")` + white digit (`99+` cap) inside the chip, after the topic name. |
| 7 | Trailing `+` button | Always last in the strip, opens `TopicCreateSheet` (Catalyst auto-renders as centered native modal). |
| 8 | Right-click on chip | Native macOS context menu — Mark as read / Pin·Unpin / Archive (General excluded from Archive). |
| 9 | Hover state | `.macHover()` extension — `.hoverEffect(.highlight)` on Catalyst. |
| 10 | Keyboard / search / `⌘T` shortcut | Out of scope for v1 — same v1.1 deferrals as the popover spec. |

### 0.2 Files in the shipped implementation

| File | Status |
|---|---|
| `GitchatIOS/Features/Conversations/Topics/TopicTabsStrip.swift` | **NEW** — Catalyst-only, file-level `#if targetEnvironment(macCatalyst)`. ~150 lines. Owns the chip rendering, ordering, hover, context menu, `+` button, create sheet, realtime event subscription, and async `load`/`markRead`/`archive` actions. |
| `GitchatIOS/Features/Conversations/Topics/TopicListContent.swift` | **KEPT** — the iOS-sheet refactor remains valuable as a clean split between content and chrome; the iOS sheet still uses it. |
| `GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift` | **KEPT (slim)** — iOS sheet wrapper, unchanged from the popover-spec refactor. |
| `GitchatIOS/Features/Conversations/Topics/TopicListPopover.swift` | **DELETED** — popover never anchored; superseded. |
| `GitchatIOS/Features/Conversations/ChatDetailView.swift` | **MODIFIED** — adds `.safeAreaInset(edge: .top) { TopicTabsStrip(...) }` on `chatShell` (Catalyst-only). The `.popover` modifier from the popover spec was reverted in the same edit. The root `.sheet` for `TopicListSheet` keeps its `#if !targetEnvironment(macCatalyst)` gate (sheet path is iPhone-only — Catalyst entry is the strip). |

### 0.3 Behaviour contract for the strip

- **Switch topic:** click chip → `vm.setTarget(.topic(picked, parent:))` + `resolvedTarget` updates → chat detail re-loads messages for the new topic. Strip stays visible; the new chip is highlighted.
- **Create topic:** click `+` → `TopicCreateSheet` opens as a centered macOS modal. On submit, `TopicListStore.append(...)` is invoked; the strip refreshes inline because the store is `@StateObject`. No auto-switch — preserves Decision #8 from the mobile spec.
- **Realtime event:** `NotificationCenter.gitchatTopicEvent` → `store.applyEvent(...)`. Chips re-order / unread badges update / archived topics drop out inline.
- **Right-click:** native macOS context menu — Mark as read / Pin·Unpin / Archive (General excluded from Archive). Uses the same actions as the iOS sheet's `TopicListContent`.
- **First load:** the strip's `.task` calls `APIClient.fetchTopics(parentId:)` only if the store has no topics for this parent yet (de-dupes with `ChatDetailView.resolveTarget`'s prior fetch).
- **Empty / loading / error states:** not rendered as a separate state — when topics list is fetching, strip shows whatever the store has (likely just General if `resolveTarget` already populated it). API failure is silent at the strip level (the underlying `resolveTarget` already surfaces errors).

### 0.4 Out of scope for the pivot (kept as v1.1 follow-ups)

Same as the popover spec — `⌘T` keyboard shortcut, search filter, last-active-topic memory, conversation-list sidebar embedding, 3rd-column split-view layout. Plus: explicit "you have many topics" overflow UX (e.g. "Show all" → reuses `TopicListContent` in a popover/sheet). Right now the strip simply scrolls horizontally.

### 0.5 Verification

- `xcodegen generate` clean. `TopicTabsStrip.swift` has 4 refs in `project.pbxproj`; `TopicListPopover.swift` has 0 refs (deleted).
- `xcodebuild generic/platform=iOS Simulator` → `BUILD SUCCEEDED`.
- `xcodebuild platform=macOS,variant=Mac Catalyst` → `BUILD SUCCEEDED`.
- Manual scenarios still pending Vincent's verification on the live Catalyst build.

---

---

## 1. Overview

The mobile iOS topic feature shipped 2026-04-30 (per the design referenced above) introduced `TopicListSheet`, `TopicCreateSheet`, `TopicRow`, `TopicListStore`, and the `ChatTarget` enum. On iPhone/iPad these render as bottom sheets with `presentationDetents([.medium, .large])`. On Mac Catalyst the same code compiles and runs, but renders the topic list as a small floating modal in the middle of a wide Mac window — visually out of place and not aligned with how Mac users expect a list switcher to behave.

This spec adds a Catalyst-only **popover** UX for the topic list, anchored on the chat header, while keeping the iPhone/iPad sheet path completely unchanged. Backend and extension are out of scope.

### 1.1 Goals

- Replace the Catalyst topic-list rendering with a native macOS popover anchored on `ChatDetailTitleBar`.
- Keep `TopicCreateSheet` as-is — `.sheet` on Catalyst already renders as a centered native modal, which is the correct Mac UX.
- Reuse all existing topic plumbing (`TopicListStore`, `TopicRow`, `APIClient+Topic`, `TopicSocketEvent`) without modification.
- Match Catalyst conventions already established in the repo (`MacShellView`, `MacRowStyle`, `MacHover`, `MacEscapeToHome`) — file-level `#if targetEnvironment(macCatalyst)` for Mac-only views, single-line `.macHover()` extension for hover states.
- Zero behavior change on iPhone and iPad.

### 1.2 Non-goals (deferred to v1.1 or follow-up issues)

- Keyboard shortcut `⌘T` to toggle the popover from a focused chat.
- Search field at the top of the popover to filter topics by name.
- Last-active-topic memory per parent group (currently re-anchors on General when re-entering).
- 3rd-column / split-view layout (Telegram Desktop forum sidebar pattern).
- Sidebar embedding (parent row expanding to show topics underneath).
- iPad-specific UI tweaks — iPad continues to use the sheet path.
- Custom Mac window chrome / traffic lights.
- Backend changes, extension changes, conversation sidebar (`ConversationsListView`) changes.
- Optimistic insert when creating a topic — keeps Decision #8 from the mobile spec (wait for BE response).
- Topic settings panel (rename / delete / permissions UI) — keeps the existing context menu (Mark as read / Pin / Archive).

### 1.3 Decisions matrix

| # | Question | Decision |
|---|---|---|
| 1 | Where does the topic list render on Catalyst? | **SwiftUI `.popover`**, anchored on `ChatDetailTitleBar` in the chat toolbar. Click-out and Esc dismiss automatically. |
| 2 | Where does `TopicCreateSheet` render on Catalyst? | **`.sheet` unchanged.** SwiftUI on Catalyst renders `.sheet` as a centered native modal — already Mac-correct. |
| 3 | Code organisation for Catalyst variant | **Approach 2 — separate file gated by `#if targetEnvironment(macCatalyst)` at the top of the file.** Matches `MacShellView.swift`, `MacRowStyle.swift`. |
| 4 | Refactor of existing `TopicListSheet` | **Split into `TopicListContent` (cross-platform body) + `TopicListSheet` (iOS wrapper).** Lets the popover reuse the body. |
| 5 | Popover dimensions | **380pt wide × 520pt tall, fixed.** Aligned with Slack thread switcher (~360×500) and Telegram Desktop forum dropdown (~400×550). |
| 6 | Header bar inside popover | **Plain `HStack` with title + create button.** No `NavigationStack`, no `.toolbar` — saves vertical space and avoids Mac toolbar styling. |
| 7 | Hover state on rows | **`.macHover()` extension.** Already exists at `Core/UI/MacHover.swift`. |
| 8 | Right-click context menu | **Reuse the existing `.contextMenu` modifier on `TopicRow`.** Catalyst renders it as a native macOS right-click menu — no new code needed. |
| 9 | Esc and click-out dismissal | **Built-in to SwiftUI `.popover` on Catalyst.** No `MacEscapeToHome` helper required. |
| 10 | State binding | **Reuse existing `@State showTopicSheet: Bool` in `ChatDetailView`.** Both the iOS sheet and the Catalyst popover bind to the same state. No new state. |

---

## 2. Architecture & file changes

### 2.1 Refactor `TopicListSheet` into content + wrapper

`gitchat-ios-native/GitchatIOS/Features/Conversations/Topics/`:

```
TopicListContent.swift     [NEW — cross-platform body]
  struct TopicListContent: View
    @StateObject store, @State isLoading/loadError/showCreate
    body: list / loadingPlaceholder / emptyState / errorBanner
    actions: load(), markRead(), togglePin(), archive()
    (no NavigationStack, no toolbar, no outer .sheet)

TopicListSheet.swift       [SLIM — iOS wrapper, behavior unchanged]
  struct TopicListSheet: View
    NavigationStack {
      TopicListContent(...)
        .toolbar { ToolbarItem(.topBarTrailing) { + button → showCreate = true } }
    }
    .sheet(isPresented: $showCreate) {
      TopicCreateSheet(...)
        .presentationDetents([.medium])    // iOS only
    }

TopicListPopover.swift     [NEW — Catalyst-only, #if targetEnvironment(macCatalyst) at file top]
  struct TopicListPopover: View
    VStack {
      HStack { Text("Topics").font(.headline) ; Spacer() ; Button(plus.circle.fill) { showCreate = true } }
        .padding(.horizontal, 16).padding(.vertical, 12)
      Divider()
      TopicListContent(...)
    }
    .frame(width: 380, height: 520)
    .sheet(isPresented: $showCreate) {
      TopicCreateSheet(...)               // no .presentationDetents — Catalyst centered modal
    }
```

`TopicListContent` exposes the same parameters the existing sheet has — `parent: Conversation`, `activeTopicId: String?`, `onPickTopic: (Topic) -> Void` — plus an internal `@Binding var showCreate` so the wrapper can drive the Create flow from its own toolbar/header.

**Rationale for the split:** the iOS `.toolbar { + button }` requires a `NavigationStack` ancestor; the Catalyst popover header is just a plain `HStack`. Owning the create-button + outer `.sheet` in the wrapper keeps `TopicListContent` free of platform-specific chrome.

### 2.2 New file: `TopicListPopover.swift`

The wrapper owns `@State showCreate`, owns the `+ New Topic` button, and owns the outer `.sheet`. `TopicListContent` accepts `showCreate` as a `@Binding` so the empty-state's "+ New Topic" button (already inside `TopicListContent.emptyState`) can drive the wrapper's create sheet too.

```swift
// GitchatIOS/Features/Conversations/Topics/TopicListPopover.swift
#if targetEnvironment(macCatalyst)
import SwiftUI

struct TopicListPopover: View {
    let parent: Conversation
    let activeTopicId: String?
    let onPickTopic: (Topic) -> Void

    @State private var showCreate = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Topics").font(.headline)
                Spacer()
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Topic")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            TopicListContent(
                parent: parent,
                activeTopicId: activeTopicId,
                showCreate: $showCreate,            // bound from wrapper
                onPickTopic: onPickTopic
            )
        }
        .frame(width: 380, height: 520)
        .sheet(isPresented: $showCreate) {
            TopicCreateSheet(parent: parent) { newTopic in
                TopicListStore.shared.append(newTopic, parentId: parent.id)
            }
        }
    }
}
#endif
```

The iOS `TopicListSheet` wrapper passes the same `$showCreate` binding through to `TopicListContent`. `TopicListContent` exposes `showCreate: Binding<Bool>` instead of an internal `@State` so both wrappers can present the create sheet from a single source of truth.

### 2.3 ChatDetailView — anchor the popover on the title bar

`ChatDetailView.swift` has two relevant sites:

- **Line 158-172** (root `.sheet`): existing iOS sheet path. Gate it with `#if !targetEnvironment(macCatalyst)` so Catalyst skips it.
- **Line 290-302** (toolbar `ToolbarItem(.principal)` containing `ChatDetailTitleBar`): attach `.popover` here on Catalyst.

```swift
ToolbarItem(placement: .principal) {
    ChatDetailTitleBar(
        conversation: vm.conversation,
        vm: vm,
        onTap: {
            if case .topic = vm.target {
                showTopicSheet = true
            } else if vm.conversation.isGroup {
                showMembers = true
            }
        }
    )
    #if targetEnvironment(macCatalyst)
    .popover(
        isPresented: $showTopicSheet,
        attachmentAnchor: .rect(.bounds),
        arrowEdge: .top
    ) {
        if case .topic(_, let parent) = resolvedTarget {
            TopicListPopover(
                parent: parent,
                activeTopicId: resolvedTarget?.conversationId,
                onPickTopic: { picked in
                    vm.setTarget(.topic(picked, parent: parent))
                    resolvedTarget = .topic(picked, parent: parent)
                    showTopicSheet = false
                }
            )
        }
    }
    #endif
}
```

The two existing entry points that set `showTopicSheet = true` (toolbar `onTap` at line 296 and custom-header `onHeaderTap` at line 488) both flow through the same `@State` binding — the popover anchors on the toolbar title bar regardless of which path triggered the state change.

The custom-header `onHeaderTap` path (`ChatDetailView.swift:486-492` and the source `ChatView.swift:299`) is dead on Catalyst because `ChatView.chatHeader` is gated by `#if !targetEnvironment(macCatalyst)` at `ChatView.swift:270`. The toolbar-anchored popover is the only entry point that needs to exist on Catalyst.

### 2.4 Files touched

| File | Change |
|---|---|
| `GitchatIOS/Features/Conversations/Topics/TopicListContent.swift` | **NEW** (~150 lines, moved from existing `TopicListSheet` body + actions) |
| `GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift` | Slim down (~40 lines), iOS-only wrapper, behavior identical |
| `GitchatIOS/Features/Conversations/Topics/TopicListPopover.swift` | **NEW** (~50 lines), Catalyst-only |
| `GitchatIOS/Features/Conversations/ChatDetailView.swift` | One `#if`-gated branch on the toolbar title bar; wrap root `.sheet` with `#if !targetEnvironment(macCatalyst)` |
| `project.yml` | No change |
| `xcodegen` regenerate | Required after the two new files are added |

### 2.5 Files NOT touched (deliberate)

`TopicCreateSheet.swift`, `TopicRow.swift`, `TopicListStore.swift`, `APIClient+Topic.swift`, `TopicSocketEvent.swift`, `TopicColor.swift`, `TopicEmojiPresets.swift`, `MacShellView.swift`, `ConversationsListView.swift`, `Models.swift`. Backend (`gitchat-webapp/backend/`) and extension (`gitchat_extension/`) are zero-touch.

---

## 3. Visual spec

### 3.1 Popover frame

- Width: 380pt (fixed)
- Height: 520pt (fixed)
- Anchor: `ChatDetailTitleBar` bounds (`attachmentAnchor: .rect(.bounds)`)
- Arrow: `arrowEdge: .top` — popover hangs below the title bar with the arrow pointing up.
- Background: SwiftUI default (vibrancy material on Catalyst). No override.

### 3.2 Internal layout

```
┌─────────────────────────────────────────┐ 380pt
│  Topics                          [ + ]  │ ← Header (HStack), 44pt, padding (16,12)
├─────────────────────────────────────────┤   Divider
│  Pinned                                 │ ← Section label (List section)
│  💬 General                    14:32 ●3 │ ← TopicRow, 60pt
│  🐛 Bugs                       12:10 @1 │
├─────────────────────────────────────────┤
│  All topics                             │
│  🚀 v2.0                       09:45    │
│  🎨 Design                     Yesterday│
│  …                                      │ ← internal scroll
└─────────────────────────────────────────┘
                                           520pt
```

### 3.3 Topic rows

- Reuse `TopicRow` unchanged.
- Apply `.macHover()` at the row site inside `TopicListContent.row(for:)` — the extension is a no-op on iOS, so no iPhone behavior change.
- `.contextMenu` already attached (Mark as read / Pin/Unpin / Archive) — Catalyst renders it as a native right-click menu automatically.
- Active topic indicator: `Color("AccentColor").opacity(0.08)` background, already in `TopicRow`.

### 3.4 Loading / empty / error states

Reuse `loadingPlaceholder`, `emptyState`, `errorBanner` from `TopicListContent`. They are wrapped in `VStack { ... }.frame(maxWidth: .infinity, maxHeight: .infinity)` so they fill the 380×520 popover frame correctly.

### 3.5 TopicCreateSheet on Catalyst

- File unchanged.
- When `.sheet(isPresented: $showCreate)` fires from inside `TopicListPopover`, SwiftUI on Catalyst renders the sheet as a **floating centered modal** stacked above the popover. This is the standard macOS pattern.
- The Catalyst branch does **not** apply `.presentationDetents([.medium])` — detents are an iOS concept and ignored on Catalyst, but omitting keeps the call site clean.

### 3.6 No new tokens / colors / fonts

Every visual primitive used here already exists in `Core/UI/`. No new color asset, no new font scale, no new shape primitive.

---

## 4. Behavior contracts

| Action | Trigger | State change | API / socket | UI feedback |
|---|---|---|---|---|
| Open popover | Click `ChatDetailTitleBar` while `vm.target == .topic` | `showTopicSheet = true` | `TopicListContent.task { load() }` runs on first open; `GET /topics?parentId=…`. Cached in `TopicListStore` — re-opens skip the call unless the store is cold. | Popover slides out below the title bar with arrow up. Loading skeleton shown if the store has no entries yet. |
| Switch topic | Click a row in the popover | `vm.setTarget(.topic(picked, parent:))` + `resolvedTarget = .topic(...)` + `showTopicSheet = false` | None at the UI layer. `ChatViewModel.setTarget` reloads messages for the new topic via the existing pipeline. | Popover closes immediately; chat detail switches to the new topic. |
| Open create sheet | Click `+` in the popover header | `showCreate = true` (state inside `TopicListPopover`) | None | `TopicCreateSheet` renders as a Mac-native centered modal stacked over the popover. |
| Confirm create | Submit inside `TopicCreateSheet` | `TopicListStore.shared.append(newTopic, parentId:)` | `POST /topics` (existing) | Sheet closes; popover refreshes the row inline because `TopicListStore` is a `@StateObject` published by `TopicListContent`. **Does not auto-switch** to the newly created topic — preserves Decision #8 from the mobile spec. |
| Cancel create | Click outside the create sheet, or Esc inside it | `showCreate = false` | None | Sheet closes; popover keeps its state. |
| Right-click row | Right-click a topic row | None | If the user picks an item: Mark as read → `markTopicRead`, Pin/Unpin → local only (no API), Archive → `archiveTopic` (with 403 toasts on permission failure, existing). | Native macOS context menu shown at the cursor; popover stays open. |
| Hover row | Mouse moves over a row | None | None | `.hoverEffect(.highlight)` fades the row background up to ~8% opacity. |
| Realtime event | `NotificationCenter` `.gitchatTopicEvent` arrives while popover is open | `TopicListStore.shared.applyEvent(evt)` (existing handler in `TopicListContent.onReceive`) | None at the UI layer; the socket subscription is unchanged. | The relevant row updates inline — unread badge, last-message preview, etc. No reload, no reorder unless the BE event mandates it. |
| Click outside popover | Click anywhere outside popover bounds | `showTopicSheet = false` (auto by SwiftUI) | None | Popover closes. |
| Esc key | Press Escape with the popover focused | `showTopicSheet = false` (auto by SwiftUI) | None | Popover closes. |
| Switch chat | User clicks a different conversation in the sidebar while popover is open | `ChatDetailView` re-inits for the new conversation; `showTopicSheet` resets to `false` (view `@State`). | New chat's load runs as normal. | Popover for the previous chat closes automatically due to the view-init lifecycle. |

### 4.1 Invariants preserved from the mobile spec

1. The popover does **not** change the auto-open-General logic in `resolveTarget()` (`ChatDetailView.swift:227`). Entering a topic-enabled group still anchors on General; the popover is purely a switcher afterwards.
2. The popover does **not** persist its own state. Open/close fully rebuilds content from `TopicListStore` — the store remains the single source of truth.
3. The popover does **not** alter the optimistic-send pipeline. It is purely a navigation surface; no message send/receive code is touched.

---

## 5. Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Group does not have topics enabled | The title-bar `onTap` does not set `showTopicSheet = true` because the `if case .topic = vm.target` guard short-circuits. Popover never triggers. Same as iPhone today. |
| 2 | Topics list is empty (group has topics enabled but none exist yet) | `TopicListContent.emptyState` ("💬 No topics yet" + "+ New Topic" button) renders inside the 380×520 popover frame. No special styling required. |
| 3 | API `fetchTopics` fails | `errorBanner` with a `Retry` button renders. The popover does not auto-close. |
| 4 | The topic the user is currently reading is archived by another user | Realtime event → `TopicListStore.applyEvent` removes the topic from the list → row disappears from the popover. The chat detail keeps showing the archived topic (server still allows reads). The user must reopen the popover and pick a different topic. **No auto-redirect** — preserves the mobile-spec contract. |
| 5 | Window resized while the popover is open | SwiftUI repositions the popover relative to the anchor automatically. The Catalyst window's minimum width (configured via `MacShellView.applyMacSidebarWidth`) is well above 380pt, so the popover never clips. |
| 6 | User opens popover, then clicks a different chat in the sidebar | `ChatDetailView` rebuilds for the new conversation, `showTopicSheet` resets to `false` (view `@State` reset on init). Popover closes automatically. |
| 7 | Custom header path (`ChatDetailView.swift:488` `onHeaderTap`) on Catalyst | **Resolved.** The custom header (`ChatView.chatHeader`) is gated by `#if !targetEnvironment(macCatalyst)` at `ChatView.swift:270`, so it does not render on Catalyst at all. On Catalyst only the SwiftUI toolbar `ChatDetailTitleBar` (line 296 path) fires `showTopicSheet = true` — the popover anchor on that toolbar item is sufficient. The `onHeaderTap` closure at line 488 is dead on Catalyst; no extra modifier needed. |
| 8 | iPad with Magic Keyboard trackpad | `targetEnvironment(macCatalyst)` is **false** on iPad — the sheet path stays. Hover and right-click on iPadOS do not exercise the Catalyst code. This is intentional — iPad is iOS UX. |
| 9 | Catalyst app with multiple windows (`Cmd+N`) | Each window has its own `ChatDetailView` instance with its own `@State showTopicSheet` — popovers across windows are independent. **Confirm during implementation:** check `Info.plist` and `Scene` configuration for whether Gitchat currently supports multi-window. If not yet supported, this case does not arise. |
| 10 | Long topic name | `TopicRow.Text(...).lineLimit(1)` truncates as today. Hover state still applies to the full row width. |

---

## 6. Test plan

The repository has no XCTest target (per `gitchat-ios-native/CLAUDE.md`). Verification is `xcodebuild` compile + manual scenarios on simulator/device. UI automation is available via `idb` for follow-up coverage.

### 6.1 Compile verification

```bash
cd gitchat-ios-native

# 1. Regenerate project after adding the two new files
xcodegen generate

# 2. Confirm the new files are in project.pbxproj
grep -c "TopicListContent.swift" GitchatIOS.xcodeproj/project.pbxproj   # expect ≥1
grep -c "TopicListPopover.swift" GitchatIOS.xcodeproj/project.pbxproj   # expect ≥1

# 3. Build for both targets — each must compile cleanly.
#    Pick whichever iPhone simulator is installed locally
#    (run `xcrun simctl list devices available` to see options).
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'generic/platform=iOS Simulator' build                     # iOS sim — sheet path
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' build                # Catalyst — popover path
```

### 6.2 iPhone regression — sheet path must be unchanged

iPhone 15 simulator, login as a user with a `topicsEnabled` group:

- [ ] Tap the chat header chip → `TopicListSheet` slides up from the bottom with `.medium` detent.
- [ ] Drag indicator visible at the top.
- [ ] Tap a topic → sheet dismisses, chat switches to the new topic.
- [ ] Tap "+" in the toolbar → `TopicCreateSheet` stacks above (sheet on sheet).
- [ ] Long-press a topic row → context menu (Mark as read / Pin / Archive).
- [ ] Empty / loading / error states render normally.

Goal: **no observable change** on iPhone after the refactor.

### 6.3 Mac Catalyst — new popover path

Catalyst app, same user:

- [ ] Click the chat header → popover opens directly under the title bar with the arrow pointing up.
- [ ] Popover dimensions are 380×520 and not clipped by the default window size.
- [ ] Topic rows render fully: emoji + name + last preview + timestamp + unread badges.
- [ ] **Hover** mouse over a row → background highlight engages (`.macHover()` active).
- [ ] **Right-click** a row → native macOS context menu appears at the cursor with Mark as read / Pin/Unpin / Archive.
- [ ] Click a topic → popover closes; chat detail switches to the new topic.
- [ ] Click "+" in the popover header → `TopicCreateSheet` opens as a centered native macOS modal (no bottom-sheet drag indicator); the popover is still present behind it.
- [ ] Submit create → sheet closes; popover refreshes with the new topic in the list; chat **does not** auto-switch to the new topic.
- [ ] Cancel create (Esc / click outside) → sheet closes; popover state preserved.
- [ ] Press **Esc** while the popover is focused → popover closes.
- [ ] Click anywhere outside the popover → popover closes.
- [ ] While the popover is open, send a message from another device into a non-active topic → that topic's row updates its unread badge inline (no reload, no flicker).
- [ ] Switch to a different chat in the sidebar while the popover is open → popover closes automatically; the new chat loads normally.

### 6.4 Cross-platform smoke

- [ ] DM and non-topic group on iPhone and Catalyst → tapping the header **does not** trigger popover or sheet (the `if case .topic` guard still short-circuits).
- [ ] Logout / login → popover and sheet still open after a fresh session.
- [ ] App background → foreground while popover is open (Catalyst `Cmd+H`) → popover state on resume (closed or preserved — both acceptable; record observed).

### 6.5 (Resolved at design time — custom header is iOS-only)

`ChatView.chatHeader` is gated by `#if !targetEnvironment(macCatalyst)` at `ChatView.swift:270`, so the custom header does not render on Catalyst. The toolbar `ChatDetailTitleBar` is the only header path on Catalyst, and the popover anchored on it is sufficient. No runtime verification needed.

---

## 7. Roll-out and follow-ups

- Branch: `vincent-feat-catalyst-topic-popover` off `main`.
- Single PR. No backend or extension PRs.
- Single commit acceptable; the user (Vincent) will commit manually after manual verification per the repo's "no auto-commit" convention.
- After merge, open follow-up issues for the v1.1 deferrals listed in §1.2 (keyboard shortcut, search filter, last-active-topic memory).
- Update `gitchat_extension/docs/contributors/vincent.md` in the same commit per cross-project convention.
