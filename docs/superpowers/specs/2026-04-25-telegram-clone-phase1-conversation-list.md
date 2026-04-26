# Phase 1: Conversation List — Telegram Clone Spec

> **Revision 2** (2026-04-26) — Updated per 4-expert review + DESIGN.md compliance.
> Revision 1 (2026-04-25) — Initial draft.

## Objective

Conversation list must match the Telegram iOS experience. User opens the app and immediately knows the status of every conversation without tapping in.

## Scope: Option B (Social Messaging) — no voice chat

## Compliance

This spec follows `docs/design/DESIGN.md`. All spacing, typography, and color values use the design system. Deviations are explicitly marked with rationale.

---

## Design Tokens

All values centralized here. Implementation must reference these tokens — no inline hex or magic numbers.

### Colors (semantic — auto-adapt dark mode)

| Token | Light | Dark | SwiftUI |
|-------|-------|------|---------|
| `accent` | #D16238 | #D16238 | `Color("AccentColor")` |
| `timestampRead` | systemGray | systemGray | `Color(.systemGray)` |
| `draftRed` | systemRed | systemRed | `Color(.systemRed)` |
| `onlineGreen` | systemGreen | systemGreen | `Color(.systemGreen)` |
| `systemMessage` | systemGray2 | systemGray2 | `Color(.systemGray2)` |
| `checkSent` | systemGray | systemGray | `Color(.systemGray)` |
| `checkRead` | accent | accent | `Color("AccentColor")` |
| `badgeMuted` | systemGray | systemGray | `Color(.systemGray)` |
| `textPrimary` | — | — | `.primary` |
| `textSecondary` | — | — | `.secondary` |
| `separator` | — | — | `Color(.separator)` |
| `rowBackground` | — | — | `Color(.systemBackground)` |
| `pinnedBackground` | accent 8% | accent 8% | `Color("AccentColor").opacity(0.08)` |

> **Note on checkmark color:** Telegram uses green for read checkmarks. We intentionally use `accent` (brand orange) to differentiate from Telegram. This is a brand decision, not a bug.

> **Dark mode:** All tokens use UIKit semantic colors or asset catalog colors that auto-adapt. The online dot border must use `Color(.systemBackground)` (not hardcoded white) to match the row background in both modes.

### Typography (semantic fonts per DESIGN.md §1.3)

| Token | Font | Use |
|-------|------|-----|
| `titleUnread` | `.headline` (17pt semibold) | Conversation name when unread |
| `titleRead` | `.body` (17pt regular) | Conversation name when read |
| `senderName` | `.subheadline` weight `.semibold` | Sender prefix in group preview |
| `previewText` | `.subheadline` (15pt regular) | Message preview |
| `timestamp` | `.footnote` (13pt regular) | Timestamp, right column meta |
| `badgeCount` | `.footnote` weight `.bold` | Unread count inside badge |

> **Dynamic Type:** Use semantic fonts as listed — they scale automatically. Avatar size stays fixed. Row height grows with text. Test at accessibility XXXL.

### Spacing (per DESIGN.md §1.1 — multiples of 4 or 8)

| Token | Value | Use |
|-------|-------|-----|
| `rowPaddingV` | 12pt | Row vertical padding |
| `rowPaddingH` | 16pt | Row horizontal padding |
| `avatarContentGap` | 12pt | Avatar to text content |
| `contentLineGap` | 4pt | Between title / sender / preview lines |
| `badgeGap` | 4pt | Between unread badge and mention badge |

### Sizing

| Token | Value | Notes |
|-------|-------|-------|
| `avatarSize` | 56pt | Telegram-clone override (DESIGN.md iOS default = 50pt). 56pt = closest on-grid value to Telegram's measured 58pt. |
| `groupAvatarRadius` | 16pt | Continuous corner: `RoundedRectangle(cornerRadius: 16, style: .continuous)` |
| `dmAvatarRadius` | 28pt (circle) | `Circle()` clip on 56pt = circle |
| `separatorInset` | 84pt | 16 (padding) + 56 (avatar) + 12 (gap) = 84pt |
| `unreadBadge` | minWidth 24pt, height 24pt, capsule | Expands horizontally with padding 8pt each side. Max display: "99+" |
| `mentionBadge` | 20pt diameter circle | Contains "@" in `.caption` bold 11pt, white on accent |
| `onlineDot` | 12pt, border 2pt `Color(.systemBackground)` | Positioned bottom-right of avatar |
| `senderAvatar` | 20pt round | Sender mini-avatar in group preview (multiple of 4) |
| `touchTarget` | min 44x44pt | Per DESIGN.md §1.2 |

---

## Features

### 1. Delivery Checkmarks

**Position:** Same line as timestamp, top-right, before timestamp.

**States:**
| State | Visual | Color token |
|-------|--------|-------------|
| Sending (local-id, no server id) | `clock` SF Symbol (12pt) | `checkSent` |
| Sent to server (has server id) | Single `checkmark` (12pt) | `checkSent` |
| Read by recipient | Custom double-checkmark asset (16x12pt) | `checkRead` |
| Incoming message | No checkmark | — |
| Failed (`unsent_at != nil`) | `exclamationmark.circle` (12pt) | `Color(.systemRed)` |

**Local-id convention:** Optimistic messages use IDs prefixed with `"local-"`. A message has a server id when `!message.id.hasPrefix("local-")`.

**Logic:**
- "sent" = `last_message.sender == currentUser.login` AND message has server id
- "read" = `otherReadAt >= last_message.created_at` (from MessageCache)
- Group: "read" = at least 1 member has `readCursor >= created_at`
- Cache the computed `isRead` boolean per conversation — do not recompute in the view body

**Edge cases (P0):**
- `last_message.created_at` = nil → no checkmark
- `last_message` = nil (empty conversation) → no checkmark
- `readCursor` = nil (never opened) → fallback to "sent"
- Optimistic send (local-id) → show clock icon until server id arrives

**Known limitation:** Conversations never opened locally will show "sent" instead of "read" due to missing MessageCache data. Future BE fix: add `otherReadAt` to `listConversations` response.

**Accessibility:** `.accessibilityLabel("Sending")` / `"Sent"` / `"Read"` / `"Failed to send"` per state.

---

### 2. Typing in List — DEFERRED (pending BE confirmation)

> **Status:** Skipped for Phase 1. Requires BE confirmation that `subscribe:user` forwards `typing:start`/`typing:stop` for all conversations. Currently typing events may only route through `subscribe:conversation` (per-chat room), meaning the conversation list would not receive them. **Action: Request BE to emit typing events to `user:<login>` room.**

**Display:** Replace preview text with typing text in `accent` color.

**Format:**
- DM: `"typing..."`
- Group 1 person: `"alice typing..."`
- Group 2 people: `"alice, bob typing..."`
- Group 3+: `"3 people typing..."`

**Priority:** Draft > Typing > Preview (if draft exists, hide typing)

**Architecture (revised per review):**
- Create `TypingStore` as `@MainActor ObservableObject`
- Use **per-conversation `CurrentValueSubject<Set<String>, Never>`** — NOT a single `@Published` dictionary (avoids O(n) row invalidation)
- Each `ConversationRow` subscribes to its own subject via `.onReceive(TypingStore.shared.publisher(for: convoId))`
- Filter `login != currentUser.login`

**Socket binding (revised per review):**
- Do NOT set `SocketClient.onTyping` directly (breaks ChatDetailView)
- Switch to `NotificationCenter` pattern (like existing `gitchatMessageSent`) or change `onTyping` to a multi-subscriber closure array
- Bind once in `SocketClient.connect()`

**Timeout implementation:**
- Use a single `DispatchSourceTimer` that sweeps stale entries every 1 second (not one timer per typing event)
- Clear entry if no follow-up event within **5 seconds**

**Edge cases (P0):**
- Socket disconnect: clear all typing state
- Draft + typing simultaneous: show draft, hide typing
- Reconnect: `subscribe:user` re-triggers typing state for active typers

**BE dependency: BLOCKER** — Confirm `subscribe:user` socket event forwards typing events for ALL conversations. If not, this feature requires BE update before implementation.

**Animation:** Crossfade between preview and typing text: `.transition(.opacity.animation(.easeInOut(duration: 0.2)))`.

**Accessibility:** `.accessibilityLabel("[Name] is typing")`.

---

### 3. Draft Indicator

**Display:** `"Draft: "` in `draftRed` + draft text in `textSecondary`, replaces preview.

**Priority:** Highest (Draft > Typing > Preview)

**Architecture (revised per review):**
- Create `DraftStore` as `@MainActor ObservableObject` with reactive publishing
- Load all drafts from UserDefaults into a `[String: String]` dictionary on init
- Publish changes via per-conversation subjects (same pattern as TypingStore)
- Update on `Notification.Name("draftChanged")` posted from ChatDetailView
- Do NOT read UserDefaults per-row on every render

**Data source:** `UserDefaults.standard.string(forKey: "gitchat.draft.\(conversation.id)")`

**Edge cases (P0):**
- Draft only whitespace/newlines → `trimmingCharacters(in: .whitespacesAndNewlines)`, don't show "Draft:" if empty after trim
- Draft persistence: already in UserDefaults, persists across app kill
- Returning from chat: DraftStore updates immediately via notification, no `.onAppear` dependency

**Animation:** Crossfade on appear/disappear: `.transition(.opacity.animation(.easeInOut(duration: 0.2)))`.

**Accessibility:** `.accessibilityLabel("Draft: \(draftText)")`.

---

### 4. Mention Badge (@)

**Display:** Badge "@" (`mentionBadge` token) next to unread count badge, with `badgeGap` spacing.

**Logic:** Parse `@currentUser.login` (from `AuthStore.shared.login`) in `last_message.content`, case-insensitive, with word boundary check.

**Regex:** `(?<![\\w])@username(?![\\w])` — avoids false positives in code blocks and partial matches.

**Conditions:** Only show when `displayedUnread > 0` AND mention found.

**Edge cases (P0):**
- Case-insensitive: `@SlugMacro` == `@slugmacro`
- Attachment-only messages (`content` empty, preview from `last_message_preview`): no mention badge
- Code blocks: regex handles word boundary, but can still false-positive inside inline code

**Known limitation:** Only checks last_message — mentions in older unread messages are missed. Consider gating behind feature flag until BE adds `has_mention_unread` field. Ship v1 with the limitation acknowledged in UI (no false promises).

**Animation:** Badge pop-in: `.transition(.scale.combined(with: .opacity).animation(.spring(response: 0.3)))`.

**Accessibility:** `.accessibilityLabel("You were mentioned")`.

---

### 5. Unread Polish

**Visual changes:**
- Conversation name: `titleUnread` (.headline) when unread, `titleRead` (.body) when read
- Timestamp: `accent` color when unread, `timestampRead` when read
- Online dot: `onlineGreen` on avatar when user online (existing `PresenceStore`)

**PresenceStore performance note:** Current `PresenceStore` uses single `@Published Set<String>` — any presence change invalidates all visible avatar views. File as tech debt; out of scope for this phase but impacts performance.

**Accessibility:** Compose full row label: `"\(name), \(isOnline ? "online" : ""). \(unreadCount) unread messages. \(hasMention ? "You were mentioned." : "")"`.

---

### 6. Group Avatar (Rounded Square)

**Group:** 56pt rounded square, `RoundedRectangle(cornerRadius: 16, style: .continuous)`. Show `group_avatar_url` or fallback initial letter on gradient background.

**DM:** 56pt circle (unchanged shape, updated size).

**Distinguish by:** `conversation.isGroup` (covers `is_group`, `type == "group"`, `"community"`, `"team"`).

**Replace** `GroupAvatarCluster` (stacked circles) with single rounded-square avatar. **Also update `ConversationHoldPreview`** to use the same avatar style.

**Gradient fallback palette** (7 presets, deterministic by ID hash):

| Index | Top color | Bottom color |
|-------|-----------|--------------|
| 0 | #FF885E | #FF516A |
| 1 | #FFD056 | #FF9F2F |
| 2 | #8BDB81 | #3CC665 |
| 3 | #62D4E3 | #3DA1E5 |
| 4 | #6FB3F0 | #5B8FEF |
| 5 | #D48AE5 | #B86BD5 |
| 6 | #F0849B | #E6699A |

Selection: `abs(conversation.id.hashValue) % 7`

**Initial letter:** `.title3` (20pt) bold, white, centered. If `group_name` starts with emoji or number, use first character as-is.

**Accessibility:** Avatar is decorative — mark `.accessibilityHidden(true)`. Name is read from the title label.

---

### 7. "You:" Prefix + Sender Avatar in Group

**Group outgoing:** `"You: "` in `accent` before preview text. NO sender avatar.

**Group incoming:** Sender avatar (`senderAvatar` token, 20pt round) + sender login in `senderName` font before preview text.

**Sender avatar fallback:** If `last_message.sender_avatar` is nil → show initial letter on gray circle (same pattern as user avatars).

**Rules:**
- NO "You:" on system messages (wave, join, leave, and any `type != "user"`)
- NO "You:" in DM
- Known system message types: `"wave"`, `"join"`, `"leave"`, `"system"`

**Accessibility:** Sender name is read as part of the preview label.

---

### 8. Right Column Layout

**Structure:**
```
[Checkmark + Timestamp]     <- top-right, aligned with title
[Pin / Badge / Mute]        <- bottom-right, aligned with preview
```

**Bottom-right priority rules:**

| Condition | Display |
|-----------|---------|
| Unread (not muted) | Accent badge + mention badge (if applicable) |
| Unread + muted | Gray badge (`badgeMuted`) + mute icon |
| Pinned + muted + no unread | Pin icon + mute icon |
| Pinned + no unread | Pin icon |
| Nothing | Empty |

**Icons:**
| Icon | SF Symbol | Size | Color |
|------|-----------|------|-------|
| Pin | `pin.fill` | 12pt | `.secondary` |
| Mute | `speaker.slash.fill` | 12pt | `.secondary` |

**Accessibility:** Badge reads as part of composed row label. Pin/mute read as `"Pinned"` / `"Muted"`.

---

### 9. System Messages (Italic)

**Applies to:** Wave, join, leave, and all `type != "user"` messages.

**Style:** `previewText` font with `.italic()`, color `systemMessage`.

**Accessibility:** Read as normal text — the italic style is visual only.

---

### 10. List Pagination

**Current state:** Only loads first page (30 conversations). `nextCursor` exists in API response but is unused.

**Implementation:**
- Add `nextCursor: String?` to `ConversationsViewModel`
- `loadMoreIfNeeded()` triggers when scroll nears end
- `isLoadingMore` flag prevents duplicate requests
- **Load cancellation:** Add `loadTask: Task?` that gets cancelled before starting new load (prevents stale response overwrite)
- Dedupe by `conversation.id` when merging pages — also run existing `dedupeChannels()` (by `repo_full_name`) on merged array
- Pull-to-refresh resets to page 1 and clears `locallyRead`, `locallyMuted`, `locallyUnmuted` sets

**Race condition mitigation:** When socket events (`applyIncomingMessage`) modify conversations while pagination is in-flight, merge by `id` with "newest `last_message_at` wins" semantics.

**Performance:** Disable `.animation(.spring(...), value: conversations.map(\.id))` during pagination appends — use `.animation(.none)` for batch inserts to prevent frame drops at 200+ conversations.

**Accessibility:** Loading indicator at bottom: `.accessibilityLabel("Loading more conversations")`.

---

## Rich Message Preview Types

Map `last_message.type` and attachments to preview text:

| Content type | Preview display |
|--------------|-----------------|
| Text | Message text (truncated) |
| Photo | "Photo" (with camera icon, optional) |
| Video | "Video" |
| File | Document filename |
| Voice | "Voice message" |
| Sticker/emoji | The emoji itself |
| Empty (no messages) | "No messages yet" in `systemMessage` italic |

Implementation: Create a `MessagePreviewType` helper that maps `last_message` to the appropriate display string.

---

## Timestamp Formatting

| Condition | Format | Example |
|-----------|--------|---------|
| Today | Time only | "2:34 PM" |
| Yesterday | "Yesterday" | "Yesterday" |
| This week | Day name | "Tue" |
| This year | Month/Day | "3/15" |
| Older | Month/Day/Year | "3/15/25" |

Use `RelativeDateTimeFormatter` or custom `DateFormatter` with these rules.

---

## Conversation Ordering

1. **Pinned conversations** at top (maintain user's pin order)
2. **Remaining conversations** sorted by `last_message_at` descending (newest first)

---

## Animations & Transitions

| Event | Animation | Spec |
|-------|-----------|------|
| Typing indicator appear/disappear | Crossfade | `.easeInOut(duration: 0.2)` |
| Draft indicator appear/disappear | Crossfade | `.easeInOut(duration: 0.2)` |
| Unread badge appear | Scale + fade | `.spring(response: 0.3)` |
| Mention badge appear | Scale + fade | `.spring(response: 0.3)` |
| Conversation moves to top (new message) | Row reorder | SwiftUI List default animation |
| Row tap highlight | Background color change | `Color(.tertiarySystemBackground)`, no scale (Telegram-style) |
| Long-press | Scale down | `scale: 0.97`, delay 0.12s, ramp 0.20s (existing) |
| Pull-to-refresh completion | Haptic | `UIImpactFeedbackGenerator(.light)` |
| Long-press context menu | Haptic | `UIImpactFeedbackGenerator(.medium)` |

---

## Accessibility

### VoiceOver Labels

Each `ConversationRow` should have a composed `.accessibilityElement(children: .combine)` label:

```
"[Name], [online status]. [Draft/Typing/Preview text]. [Unread count]. [Mention]. [Muted]. [Pinned]."
```

Example: `"Alice, online. Draft: hey are you free. 3 unread messages. You were mentioned. Muted."`

### Dynamic Type

- All text uses semantic fonts — scales automatically
- Avatar size stays fixed at 56pt
- Row height grows with text content
- Test at accessibility sizes (XXXL, AX1-5)
- Use `@ScaledMetric` for any remaining fixed sizes (badge padding, icon sizes)

### Color Contrast

All text/background pairs meet WCAG AA (4.5:1 for normal text, 3:1 for large text):
- Semantic colors (`.primary`, `.secondary`) meet this by default
- `accent` on white: verify ~3.7:1 — acceptable for large/bold text only. For 13pt timestamp, consider `.secondary` instead of accent on read timestamps. **Decision: keep accent for unread timestamps (bold context), use `.secondary` for all other small text.**

### RTL Support

- Right column (checkmarks + timestamp) stays trailing-aligned regardless of layout direction
- Test with Arabic/Hebrew to verify mirroring

### iPad Split View

- At 1/3 width (320pt), verify 56pt avatar + content + right column fits
- Consider truncating preview text earlier at narrow widths

---

## Visual States

### Empty State (zero conversations)

Display centered: illustration + "No conversations yet" + "Start a chat" button. Use `.contentUnavailableView` pattern.

### Loading State

Shimmer skeleton matching row layout:
- Alternate circle (DM) and rounded-square (group) avatar shapes in skeleton
- 56pt avatar + two text lines + right-column placeholder
- Show 8-10 skeleton rows

### Error State

If `load()` fails, show inline error banner at top: `"Could not load conversations. Pull to retry."` with `Color(.systemRed)` accent.

### Connection Status Banner

Sticky banner below navigation bar:

| State | Text | Style |
|-------|------|-------|
| Connecting | "Connecting..." | `.secondary`, with spinner |
| Waiting for network | "Waiting for network..." | `.secondary`, with spinner |
| Updating | "Updating..." | `.secondary`, with spinner |
| Connected | Hide banner | Animated dismiss |

---

## Swipe Actions (Phase 1 scope: basic set)

| Direction | Actions | Colors |
|-----------|---------|--------|
| Leading (right swipe) | Read/Unread toggle — **DEFERRED** | `Color(.systemGreen)` |
| Trailing (left swipe) | Pin/Unpin, Mute/Unmute, Delete | Pin: `Color(.systemBlue)`, Mute: `Color(.systemOrange)`, Delete: `Color(.systemRed)` |

Use SwiftUI `.swipeActions()` modifier. Context menu (long-press) deferred to Phase 2.

> **Read/Unread swipe deferred:** `APIClient.markRead()` exists but `markUnread` endpoint does not. Implement when BE adds `markUnread`. Code comment in `ConversationsListView.swift` marks the location.

---

## Asset Requirements

### SF Symbols

| Symbol | Size | Usage |
|--------|------|-------|
| `clock` | 12pt | Sending state checkmark |
| `checkmark` | 12pt | Sent state (single tick) |
| `exclamationmark.circle` | 12pt | Failed to send |
| `pin.fill` | 12pt | Pinned indicator |
| `speaker.slash.fill` | 12pt | Muted indicator |

### Custom Assets Needed

1. **Double checkmark** — SF Symbols has no native double-check glyph. Create custom PDF vector asset, 16x12pt logical size (48x36px @3x). Alternatively: compose two `checkmark` SF Symbols with -3pt horizontal overlap.

2. **Group avatar gradient set** — 7 gradient pairs defined in the gradient table above. Implement as `LinearGradient` from top to bottom.

### Image Specs

| Image | Logical size | Pixel size @3x |
|-------|-------------|----------------|
| Conversation avatar | 56pt | 168px |
| Sender mini-avatar | 20pt | 60px |

---

## Layout Spec (revised)

| Element | Value |
|---------|-------|
| Avatar size | 56pt |
| Group avatar radius | 16pt (continuous) |
| Row padding | 12pt vertical, 16pt horizontal |
| Row gap (avatar to content) | 12pt |
| Content gap (title / sender / preview) | 4pt |
| Separator inset | 84pt from left |
| Unread badge | min 24pt width, 24pt height, capsule, 8pt horizontal padding |
| Mention badge | 20pt diameter circle |
| Online dot | 12pt, border 2pt `Color(.systemBackground)` |
| Sender avatar | 20pt round |
| Total row height | ~80pt (avatar 56 + padding 12x2), grows with Dynamic Type |

---

## Files to Modify

| File | Changes |
|------|---------|
| `ConversationsListView.swift` | ConversationRow refactor: 56pt avatar, right column VStack, checkmarks, draft, typing, mention badge, "You:" prefix, system italic, swipe actions, pagination, animations, accessibility labels |
| `SocketClient.swift` | Switch `onTyping` to multi-subscriber (NotificationCenter or closure array). Bind TypingStore in `connect()`. Add typing re-trigger on reconnect. |
| **New:** `TypingStore.swift` | Per-conversation typing state with `CurrentValueSubject`. Single sweep timer for timeouts. |
| **New:** `DraftStore.swift` | Reactive draft publishing from UserDefaults. Per-conversation subjects. |
| `ConversationsViewModel.swift` (in ConversationsListView) | Add `nextCursor`, `loadTask` cancellation, generation counter, pagination merge logic. Add `Conversation.withLastMessage()` helper. |
| `Models.swift` | No model changes needed |

## Architecture Notes

### SocketClient multi-subscriber pattern

```swift
// Replace single closure:
// var onTyping: ((String, String, Bool) -> Void)?

// With NotificationCenter:
static let typingNotification = Notification.Name("gitchatTyping")
// Post: NotificationCenter.default.post(name: Self.typingNotification,
//   object: nil, userInfo: ["conversationId": id, "login": login, "isTyping": isTyping])
```

### Conversation copy helper

```swift
extension Conversation {
    func withLastMessage(_ message: Message, preview: String?) -> Conversation {
        // Return new Conversation with updated last_message fields
        // Eliminates 17-positional-argument reconstruction
    }
}
```

### Load cancellation

```swift
private var loadTask: Task<Void, Never>?

func load() {
    loadTask?.cancel()
    loadTask = Task { @MainActor in
        // existing load logic
        guard !Task.isCancelled else { return }
        self.conversations = deduped
    }
}
```

---

## BE Dependencies

| Feature | Needs BE? | Details |
|---------|-----------|---------|
| Checkmarks | No (v1) | Uses MessageCache. Nice-to-have: add `otherReadAt` to listConversations |
| Typing in list | **DEFERRED** | BE needs to emit `typing:start`/`typing:stop` to `user:<login>` room (currently may only go to `conversation:<id>` room). Revisit after BE update. |
| @mention | No (v1) | Nice-to-have: add `has_mention_unread` field |
| Pagination | No | API already supports cursor |
| Everything else | No | Client-side only |

---

## Estimate

**~6 days** (typing deferred, revised from original 3-4 per reviewer consensus).

| Phase | Features | Est |
|-------|----------|-----|
| Day 1 | Design tokens setup, avatar refactor (56pt, rounded square, gradient), layout/typography alignment | 1 day |
| Day 2 | Draft indicator (DraftStore), "You:" prefix, system message italic, unread polish, right column layout | 1 day |
| Day 3 | Checkmarks (all states), mention badge, swipe actions | 1 day |
| Day 4 | Pagination (cursor, load cancellation, dedup, race handling) | 1 day |
| Day 5 | Animations, accessibility labels, visual states (skeleton, error, connection banner) | 1 day |
| Day 6 | Integration testing, polish, edge case verification | 1 day |
| **Deferred** | TypingStore + socket refactor (multi-subscriber) — pending BE update to emit typing to `user:<login>` room | TBD |

---

## Changelog

| Rev | Date | Changes |
|-----|------|---------|
| 2 | 2026-04-26 | DESIGN.md compliance (semantic fonts/colors/spacing grid). Added: dark mode tokens, accessibility section, animations, visual states, swipe actions, asset requirements, timestamp formatting, conversation ordering, rich message preview types, connection banner. Fixed: avatar 56pt (on-grid), typography weights (regular/semibold not semibold/bold), TypingStore architecture (per-conversation subjects), SocketClient multi-subscriber, DraftStore reactive, load cancellation, Conversation copy helper, mention regex, gradient palette, sender avatar fallback. Estimate revised to 5-7 days. |
| 1 | 2026-04-25 | Initial draft |
