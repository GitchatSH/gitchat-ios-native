# iOS Topic Feature — Design Spec

**Date:** 2026-04-28
**Author:** Vincent (driven brainstorm) — drafted via `superpowers:brainstorming`
**Status:** Awaiting review
**Target branch:** to be created off `main` (post PR #89 merge)

---

## 1. Overview

Backend (`gitchat-webapp/backend`) and the VS Code extension (`gitchat_extension`) ship a fully-implemented **Topic** feature: per-group sub-conversations with their own emoji icon, color, pin order, archive lifecycle, per-topic unread counts, and realtime broadcast over a shared parent room. iOS has zero topic code today — Slug's PR #89 ("app refactor — chat UI overhaul") delivered the chat foundation (rotated-table message list, grouped sender cells, glass message menu, etc.) that we now layer topics on top of.

This spec captures the v1 iOS topic implementation. It is **mobile-only** — backend and extension stay untouched.

### 1.1 Goals

- Mirror the extension's UX (parity with what users already know on web/desktop).
- Reuse existing iOS chat plumbing — no parallel `ChatViewModel`, no parallel message renderer.
- Follow `docs/design/DESIGN.md` (8pt grid, semantic SwiftUI fonts, GlassPill glass pattern, sheet conventions) and reuse `Core/UI/` components.
- Ship MVP scope with one stretch capability (pin/unpin) so admins can curate.

### 1.2 Non-goals (deferred to a follow-up spec)

Rename / recolor topic, unarchive, delete, close/reopen, hide-general toggle, per-user permissions UI, settings panel (enable topics / creation mode), search inside topic list, optimistic create insert, deep links (`gitchat://topic/:id`), push payload routing to specific topics, conversation-level role tracking on the client.

### 1.3 Decisions matrix

| # | Question | Decision |
|---|---|---|
| 1 | v1 capability scope | **MVP + pin/unpin** (list, create, send/receive, mark-read, archive, pin, unpin) |
| 2 | Topic UI placement in nav | **Bottom sheet** (`presentationDetents([.medium, .large])`) presented from chat header — local sheet of `ChatDetailView`, not router-driven |
| 3 | When user taps a parent group with `topicsEnabled` | **Auto-open General topic** as the active chat target; switch via sheet |
| 4 | Conversation list row for a topics-enabled parent | **Single row, unchanged layout** — no visual hint chevron, no nested sub-rows. BE aggregates `last_message_at` from topic activity (verified — see §6.2) |
| 5 | Data model | **Distinct `Topic` struct + `ChatTarget` enum** — `Conversation` only gains a single `topics_enabled: Bool?` field |
| 6 | Permission UI for admin-only actions (Pin, Unpin, Archive non-creator-owned) | **Show all actions, BE returns 403 → toast** — no client-side role tracking. Matches existing iOS pattern for delete/pin/etc. |
| 7 | Color asset strategy | **Eight new colorsets** under `Resources/Assets.xcassets/TopicColor*.colorset/` (Red, Orange, Yellow, Green, Cyan, Blue, Purple, Pink) with light/dark variants based on Apple HIG palette |
| 8 | Optimistic insert on topic create | **None** — wait for BE response (rate-limit + dup-name need server enforcement) |
| 9 | Realtime subscription model | **Subscribe to parent room only** — BE broadcasts every topic event to `conversation:{parentId}` |

---

## 2. Architecture overview

### 2.1 Data model — `Core/Models/Models.swift`

Add a `Topic` struct, a `ChatTarget` enum, and one new field on `Conversation`. Field naming follows the existing snake_case convention used by `Conversation` and `Message`.

```swift
// MARK: - Topic

struct Topic: Codable, Identifiable, Hashable {
    let id: String                          // BE conversation row id (type='topic')
    let parent_conversation_id: String
    let name: String
    let icon_emoji: String?
    let color_token: String?                // "red"|"orange"|"yellow"|"green"|"cyan"|"blue"|"purple"|"pink"
    let is_general: Bool
    let pin_order: Int?                     // 1...5, nil if unpinned
    let archived_at: String?
    let last_message_at: String?
    let last_message_preview: String?
    let last_sender_login: String?
    let unread_count: Int
    let unread_mentions_count: Int
    let unread_reactions_count: Int
    let created_by: String
    let created_at: String

    var isArchived: Bool { archived_at != nil }
    var isPinned: Bool { pin_order != nil }
    var displayEmoji: String { icon_emoji ?? "💬" }
    var hasMention: Bool { unread_mentions_count > 0 }
    var hasReaction: Bool { unread_reactions_count > 0 }
}

// MARK: - Chat target — used by ChatViewModel

enum ChatTarget: Hashable {
    case conversation(Conversation)
    case topic(Topic, parent: Conversation)

    var conversationId: String {
        switch self {
        case .conversation(let c): return c.id
        case .topic(let t, _): return t.id
        }
    }
    var parentConversationId: String? {
        switch self {
        case .conversation: return nil
        case .topic(_, let p): return p.id
        }
    }
}
```

`Conversation` gains exactly one optional field:

```swift
struct Conversation: Codable, Identifiable, Hashable {
    // ...existing fields unchanged...
    let topics_enabled: Bool?

    var hasTopicsEnabled: Bool { topics_enabled == true }
}
```

`Topic` is intentionally **not** merged into `Conversation`: doing so would force six topic-only nullable fields onto every DM/group/community row and pollute `displayTitle`, `previewText`, `displayAvatarURL` with branch logic. Keeping them separate matches the codebase precedent (`StarredRepo`, `ContributedRepo`, `RepoChannel`, `WaveSent` are each their own struct).

### 2.2 Color helper — `Core/UI/TopicColor.swift` (new)

```swift
enum TopicColorToken: String, CaseIterable, Hashable {
    case red, orange, yellow, green, cyan, blue, purple, pink

    var color: Color {
        switch self {
        case .red:    return Color("TopicColorRed")
        case .orange: return Color("TopicColorOrange")
        case .yellow: return Color("TopicColorYellow")
        case .green:  return Color("TopicColorGreen")
        case .cyan:   return Color("TopicColorCyan")
        case .blue:   return Color("TopicColorBlue")
        case .purple: return Color("TopicColorPurple")
        case .pink:   return Color("TopicColorPink")
        }
    }

    static func resolve(_ rawToken: String?) -> TopicColorToken {
        guard let raw = rawToken, let t = TopicColorToken(rawValue: raw.lowercased()) else { return .blue }
        return t
    }
}
```

Eight colorset assets are created under `Resources/Assets.xcassets/`. RGB values are picked from Apple's HIG semantic palette (System Red / System Orange / etc.) so dark mode adapts automatically; the light/dark variants are stored in each colorset's `Contents.json`.

### 2.3 Networking — `Core/Networking/APIClient+Topic.swift` (new)

Mirror the per-domain extension pattern (`APIClient+Group.swift`, `APIClient+Discover.swift`, `APIClient+Push.swift`, `APIClient+Invite.swift`).

```swift
extension APIClient {

    struct ListTopicsResponse: Decodable { let topics: [Topic] }

    func fetchTopics(parentId: String,
                     includeArchived: Bool = false,
                     pinnedOnly: Bool = false,
                     limit: Int = 100) async throws -> [Topic]

    func createTopic(parentId: String,
                     name: String,
                     iconEmoji: String?,
                     colorToken: String?) async throws -> Topic

    func archiveTopic(parentId: String, topicId: String) async throws -> Topic
    func pinTopic(parentId: String, topicId: String, order: Int) async throws -> Topic
    func unpinTopic(parentId: String, topicId: String) async throws -> Topic
    func markTopicRead(parentId: String, topicId: String) async throws

    func sendTopicMessage(parentId: String,
                          topicId: String,
                          body: String,
                          replyToId: String?,
                          attachments: [...]?) async throws -> Message

    func fetchTopicMessages(parentId: String,
                            topicId: String,
                            cursor: String?,
                            limit: Int) async throws -> [Message]
}
```

Endpoint mapping:

| iOS method | BE endpoint |
|---|---|
| `fetchTopics` | `GET /messages/conversations/:parentId/topics` |
| `createTopic` | `POST /messages/conversations/:parentId/topics` |
| `archiveTopic` | `PATCH /messages/conversations/:parentId/topics/:topicId/archive` |
| `pinTopic` | `PATCH /messages/conversations/:parentId/topics/:topicId/pin` |
| `unpinTopic` | `PATCH /messages/conversations/:parentId/topics/:topicId/unpin` |
| `markTopicRead` | `PATCH /messages/conversations/:parentId/topics/:topicId/read` |
| `sendTopicMessage` | `POST /messages/conversations/:parentId/topics/:topicId/messages` |
| `fetchTopicMessages` | `GET /messages/conversations/:parentId/topics/:topicId/messages` |

Endpoints intentionally **not** implemented in v1 (deferred): `updateTopic`, `unarchive`, `DELETE`, `close`, `reopen`, `hide-general`, `permissions` (GET/PUT), `settings` PATCH, `getTopicById` (single fetch — list + cache covers all v1 needs).

### 2.4 Realtime — `Core/Realtime/SocketClient.swift` (extend)

BE broadcasts every topic event into `conversation:{parentId}`. The existing per-conversation subscription is enough — no new room is opened. The client subscribes to a parent room when (a) the user opens a conversation, or (b) the user opens `TopicListSheet`.

Events handled in v1:

| Event | Payload | Client action |
|---|---|---|
| `topic:created` | `{ parentId, topic }` | `TopicListStore.append(topic)` for that parent. If sheet for that parent is mounted → list animates new row. |
| `topic:updated` | `{ parentId, topicId, changes }` | Patch fields (`name`, `icon_emoji`, `color_token`) — no UI for editing in v1, but state must stay correct for receivers. |
| `topic:archived` | `{ parentId, topicId, archivedBy, archivedAt }` | Set `archived_at`. Filter from list. If active `ChatTarget.topic.id == topicId` → toast `"This topic was archived"` + ChatViewModel switches target to the parent's General topic (re-fetch list, pick `is_general`) or fall back to `.conversation(parent)` if list now empty. Mirrors extension Bug 8 handling. |
| `topic:pinned` | `{ parentId, topicId, pinOrder }` | Patch `pin_order`, re-sort list. |
| `topic:unpinned` | `{ parentId, topicId }` | Set `pin_order = nil`, re-sort. |
| `topic:settings-updated` | `{ parentId, topicsEnabled, ... }` | Patch `Conversation.topics_enabled` in `ConversationsCache`. If sheet is mounted and topics just got disabled → dismiss sheet + toast. |
| `topic:message` | `{ parentId, topicId, message }` | See §2.4.1 — primary delivery path for topic chat updates. |

Events ignored (out of scope, log-and-drop): `topic:closed`, `topic:reopened`, `topic:deleted`, `topic:unarchived`. They will surface eventually via reconnect re-fetch.

#### 2.4.1 `topic:message` handling and `message:sent` deduplication

BE fires **both** `message:sent` and `topic:message` for the same logical topic message (verified: `messages.service.ts:1336–1358`, comment "Slug's FE listens on topic:message"). The extension dedupes by inspecting whether it is currently inside a topic and skipping the `message:sent` route in that case (see `gitchat_extension/src/webviews/explore.ts:2210–2230`).

iOS adopts the same approach with one twist for the conversation list:

1. `SocketClient` subscribes to both events.
2. When `topic:message` arrives:
   - Append to `MessageCache` keyed on `topicId`.
   - If the active `ChatViewModel.target` matches the topic id → forward to the chat (existing message delivery path).
   - Else → bump `topic.unread_count` in `TopicListStore` and post a `NotificationCenter` ping `.topicUnreadUpdated(parentId:topicId:)` so any mounted sheet refreshes its row.
   - **Local patch the parent row in `ConversationsCache`** — set `last_message_text / last_message_at / last_sender_login` on the parent so the main conversation list does not display stale activity. Avoids a REST round-trip; mirrors the way Slug's PR #89 patches conversation rows from `message:sent`.
3. When `message:sent` arrives **and the payload contains `topicId`** → ignore (deduplicated; `topic:message` handler already did the work). When it arrives without `topicId` → existing non-topic delivery path, untouched.

#### 2.4.2 Reconnect reconciliation

On WS reconnect, refetch the topic list for any parent currently mounted in `TopicListSheet` or active in `ChatViewModel`. Diff against `TopicListStore` and apply add/update/remove. Same pattern Slug uses for conversation re-sync after reconnect.

---

## 3. UI components

### 3.1 `TopicListSheet` — `Features/Conversations/Topics/TopicListSheet.swift` (new)

Bottom sheet presented from `ChatDetailView` when the user taps the title bar. Match `PinnedMessagesSheet` / `MembersSheet` style.

**Presentation:**
- `.sheet(isPresented:) { TopicListSheet(...) }`
- `.presentationDetents([.medium, .large])`
- `.presentationDragIndicator(.visible)`
- Background = `Color(.systemBackground)`; sheet header uses `GlassPill` for the "+" create button to match composer accents.

**Layout (8pt grid throughout):**

```
─ drag handle ─
Topics                                     [+]
in <Parent group name>
─────────────────────────────
Pinned                                          ← .footnote uppercase secondary, only if any pinned
💬 General · "last msg preview" · 12:34    [3]
🐛 Bugs    · "last msg preview" · 11:02    [12]
─────────────────────────────
All topics                                      ← .footnote uppercase secondary
🚀 v2.0    · "last msg preview" · Mon       [1]
📋 Roadmap · "last msg preview" · Sun
```

**Sort:** `pin_order ASC NULLS LAST, last_message_at DESC` (matches BE list response).

**Sections:** "Pinned" (only rendered if `topics.contains { $0.isPinned }`) and "All topics".

**Empty state:** Centered emoji + "No topics yet — create one to organize discussions" + filled "+ New Topic" button (`.borderedProminent`).

**Loading state:** Four `Skeleton`-modified placeholder rows (reuse `Core/UI/Skeleton.swift`).

**Error state:** Banner with retry button at the top of the list, same pattern as `MembersSheet`.

#### 3.1.1 `TopicRow` — `Features/Conversations/Topics/TopicRow.swift` (new)

| Property | Value |
|---|---|
| Row height | ~60pt |
| Touch target | 60pt minimum (>44pt HIG) |
| Emoji icon | 36×36pt rounded square (corner radius 10), background `TopicColorToken.color.opacity(0.18)`, emoji centered at `.title3` |
| Title | `.headline` (17pt semibold) `.primary` |
| Preview | `.subheadline` (15pt) `.secondary`, single line truncated |
| Time meta | `.footnote` (13pt) `.tertiary`, top-right (use `Core/UI/RelativeTime.swift`) |
| Unread badge | Reuse conversation-list pill style. Active row inverts (white pill + accent text); inactive shows accent pill + white text |
| Mention dot | If `topic.hasMention`, render the `@` badge — `Text("@").font(.caption.bold())` in a `mentionBadgeSize` circle filled `Color("AccentColor")`, white foreground. Match `ConversationsListView.swift:1195–1202` exactly (no shared helper exists today; copy the inline pattern). |
| Reaction dot | If `topic.hasReaction`, render `Image(systemName: "heart.fill")` in the same circle. Match `ConversationsListView.swift:1203–1210`. |
| Active highlight | If row's `topic.id == ChatViewModel.target.conversationId` → row background `Color("AccentColor").opacity(0.08)` + accent left bar 3pt |

**Long-press context menu** (`.contextMenu`, glass-style matching `MessageMenuActionList`):

- Mark as read — fires `markTopicRead`.
- Pin to position 1 / 2 / 3 / 4 / 5 (submenu) — only items the BE will accept; each tap calls `pinTopic(order:)`. On `TOPIC_PIN_ORDER_TAKEN` 409 → toast. Per a3, the submenu is shown to all users; non-admins get a 403 toast.
- Unpin — only when `topic.isPinned == true`.
- Archive — disabled for `topic.is_general == true` (BE rejects). For other topics, shown to all users; non-admins/non-creators receive a 403 toast.

### 3.2 `TopicCreateSheet` — `Features/Conversations/Topics/TopicCreateSheet.swift` (new)

Presented from the `+` button in `TopicListSheet`. `.sheet` with `.presentationDetents([.medium])`, parent sheet stays mounted underneath.

**Form (VStack spacing 16pt):**

1. **Topic name** — `TextField(...)` with `.roundedBorder` style, autofocus on appear, 50-character cap, placeholder `"e.g. Bug Reports"`. Label above: `.footnote` `.secondary` "Topic name".
2. **Icon** — `ScrollView(.horizontal)` of twelve 44×44pt buttons. Preset emojis (matching extension exactly): `💬 🐛 🚀 📋 📌 💡 🎯 ⚙️ 📊 🔥 ✨ 📚`. Default selection: `💬`. Selected button has `Color("AccentColor").opacity(0.18)` fill + 2pt accent border.
3. **Color** — HStack of eight 32×32pt colored circles wrapped in 44×44pt invisible touch areas. Iterate `TopicColorToken.allCases`. Default: `.blue`. Selected has a 3pt accent ring outside the dot.
4. **Buttons row** — `Cancel` (`.bordered`) + `Create` (`.borderedProminent`, disabled while `name.trimmed.isEmpty` or while submitting).

**Submit flow:**

1. Disable form, call `apiClient.createTopic(parentId:, name:, iconEmoji:, colorToken:)`.
2. On success → server returns `Topic` → `TopicListStore.append(topic, parentId: parent.id)` → dismiss sheet → toast `"Topic created"`.
3. On `TOPIC_NAME_TAKEN` 409 → inline error under name field: `"Name already in use"` + re-enable form (do not dismiss).
4. On `TOPIC_RATE_LIMIT` 429 → toast `"You're creating topics too fast — try again later"` + re-enable form.
5. On `TOPIC_FORBIDDEN` 403 (creation mode `admins_only`, user not admin) → toast `"Only admins can create topics in this group"` + dismiss.
6. On generic error → toast `"Could not create topic — try again"` + re-enable.

No optimistic insert — the row appears once the BE confirms (per decision #8).

### 3.3 `ChatDetailTitleBar` — modifications

When `ChatViewModel.target == .topic(t, parent: c)`:

- **Title:** `"\(t.displayEmoji) \(t.name)"` (e.g. `"💬 General"`).
- **Subtitle:** `"in \(c.displayTitle)"` in `.subheadline` `.secondary`, with a trailing `chevron.down` SF Symbol (12pt, `.tertiary`) suggesting the bar is tappable.
- **Avatar:** parent group avatar (`GroupAvatarView`, 32pt) — replaces the participant avatar.
- **Tap action:** present `TopicListSheet` (toggle local `@State`).
- **Long-press action:** reserved for v2 (quick-switch menu).

When `target == .conversation(c)` (DM, or non-topics group): existing behavior unchanged. No chevron, no tap action.

### 3.4 `ChatDetailView` — flow changes

Public signature stays `ChatDetailView(conversation: Conversation)` so `ConversationsListView`, `AppRouter`, and push routing do not change.

```swift
struct ChatDetailView: View {
    let conversation: Conversation

    @State private var resolvedTarget: ChatTarget? = nil
    @State private var showTopicSheet = false
    @StateObject private var vm: ChatViewModel = ChatViewModel.placeholder

    var body: some View {
        Group {
            if let target = resolvedTarget {
                ChatScreen(target: target, vm: vm,
                           onHeaderTap: { showTopicSheet = true })
            } else {
                ChatSkeleton()
            }
        }
        .task(id: conversation.id) {
            await resolveTarget()
        }
        .sheet(isPresented: $showTopicSheet) {
            if case .topic(_, let parent) = resolvedTarget {
                TopicListSheet(parent: parent,
                               activeTopicId: resolvedTarget?.conversationId,
                               onPickTopic: { picked in
                                   resolvedTarget = .topic(picked, parent: parent)
                                   vm.switch(to: resolvedTarget!)
                                   showTopicSheet = false
                               })
            }
        }
    }

    private func resolveTarget() async {
        if conversation.hasTopicsEnabled {
            do {
                let topics = try await apiClient.fetchTopics(parentId: conversation.id)
                let general = topics.first(where: { $0.is_general }) ?? topics.first
                resolvedTarget = general.map { .topic($0, parent: conversation) }
                              ?? .conversation(conversation)
            } catch {
                resolvedTarget = .conversation(conversation)
            }
        } else {
            resolvedTarget = .conversation(conversation)
        }
        vm.switch(to: resolvedTarget!)
    }
}
```

Switching topics inside a single chat detail session reuses the existing `ChatViewModel` instance via a `switch(to: ChatTarget)` method — it resets `messages`, cancels any in-flight fetches, marks the previous target read, and starts a fresh fetch. This avoids tearing down and re-creating the rotated `UITableView` host that PR #89 set up.

### 3.5 `ChatViewModel` — refactor

`ChatViewModel.init` takes a non-optional `target`. To accommodate the lazy resolution in §3.4 (where `resolvedTarget` is `nil` until the first `.task` fires), `ChatDetailView` constructs the ViewModel **after** the target resolves rather than at view init. Pattern:

```swift
struct ChatDetailView: View {
    let conversation: Conversation
    @State private var resolvedTarget: ChatTarget? = nil

    var body: some View {
        if let target = resolvedTarget {
            ChatScreen(target: target, vm: ChatViewModel(target: target),
                       onHeaderTap: { showTopicSheet = true })
              .id(target.conversationId)   // re-init on swap so @StateObject restarts
        } else {
            ChatSkeleton()
        }
    }
}
```

Switching topics inside an open chat (sheet → pick another topic) updates `resolvedTarget`; the `.id(target.conversationId)` modifier forces SwiftUI to discard the previous `ChatScreen`'s `@StateObject` and create a fresh `ChatViewModel(target:)` for the new target. This is simpler than introducing a `vm.switch(to:)` mutation method and matches how the chat screen already re-mounts on conversation change today. (If profiling later shows the re-mount cost is unacceptable, swap to a `switch(to:)` mutation method then.)

```swift
final class ChatViewModel: ObservableObject {
    @Published private(set) var target: ChatTarget
    // ...existing @Published state for messages, drafts, etc...

    init(target: ChatTarget) { self.target = target; ... }

    private var sendEndpoint: String {
        switch target {
        case .conversation(let c):
            return "messages/conversations/\(c.id)"
        case .topic(let t, let p):
            return "messages/conversations/\(p.id)/topics/\(t.id)/messages"
        }
    }

    private var fetchEndpoint: String { /* same shape */ }
}
```

All other ViewModel logic — optimistic message insertion, outbox, reactions, typing, presence, mentions, search — is unchanged. Only endpoint resolution branches.

The signature change from `init(conversation:)` to `init(target:)` is the one breaking refactor. To minimize risk we land it in **two commits**: (1) introduce `ChatTarget` + change ViewModel signature + adapt `ChatDetailView` to wrap existing conversations in `.conversation(c)`, no behavioral change; (2) layer topic logic on top (lazy resolve, sheet, header chevron, networking, realtime, store).

### 3.6 `ConversationsListView` — minimal changes

Per decision #4, the row layout for parent groups is unchanged. BE already aggregates `last_message_at` / `last_message_text` / `last_sender_login` onto the parent row whenever a topic message is sent (verified — see §6.2), so the existing row implementation continues to display correct activity timestamps and previews. No visual hint chevron is added in v1.

The only addition: when `SocketClient` receives `topic:message`, the conversation cache is patched locally on the parent row (see §2.4.1) so the visible activity time updates without a REST round-trip.

### 3.7 `AppRouter` / `Routes`

No new router-driven routes. `TopicListSheet` is purely local `@State` of `ChatDetailView`. Navigation to a conversation that has topics enabled flows exactly as before — `AppRouter.openConversation(parent)` → `ChatDetailView(conversation: parent)` → internal target resolution.

A future enhancement (out of v1 scope) would add `AppRouter.openTopic(_ topic: Topic, parent: Conversation)` to support deep links and topic-aware push payloads.

---

## 4. State management

### 4.1 `TopicListStore` — `Features/Conversations/Topics/TopicListStore.swift` (new)

Observable store keyed by parent conversation id. Match the deployment target (iOS 16+ → `ObservableObject`; do **not** use `@Observable` macro until the project bumps to iOS 17).

```swift
@MainActor
final class TopicListStore: ObservableObject {
    static let shared = TopicListStore()

    @Published private(set) var topicsByParent: [String: [Topic]] = [:]

    func load(parentId: String) async throws -> [Topic]
    func append(_ topic: Topic, parentId: String)
    func update(topicId: String, parentId: String, mutate: (inout Topic) -> Void)
    func archive(topicId: String, parentId: String)
    func setPinOrder(topicId: String, parentId: String, order: Int?)
    func bumpUnread(topicId: String, parentId: String, by delta: Int)
    func clearUnread(topicId: String, parentId: String)
    func applyEvent(_ event: TopicSocketEvent)
}
```

`TopicSocketEvent` is a Swift enum declared alongside `SocketClient` in `Core/Realtime/SocketClient.swift` (or a sibling file `Core/Realtime/TopicSocketEvent.swift` if `SocketClient.swift` grows too large). Cases: `.created(parentId, Topic)`, `.updated(parentId, topicId, changes)`, `.archived(parentId, topicId)`, `.pinned(parentId, topicId, order)`, `.unpinned(parentId, topicId)`, `.settingsUpdated(parentId, topicsEnabled)`, `.message(parentId, topicId, Message)`. Decoding from raw socket payloads happens in `SocketClient`; `TopicListStore.applyEvent` consumes the typed enum.

**LRU policy:** keep at most 10 parent caches in memory. When evicting, drop oldest by access timestamp. Same pattern `ConversationsCache` uses.

**Sort:** `topicsByParent[parentId]` is stored sorted (pinned section first by `pin_order ASC`, then unpinned by `last_message_at DESC`) so the UI reads top-to-bottom directly.

### 4.2 `OutboxStore` — extension

`OutboxStore` (Slug PR #75) currently stores per-conversation pending sends. Add a `topic_id: String?` field on `OutboxItem`. Endpoint resolution in the outbox flush worker reuses the same branching as `ChatViewModel.sendEndpoint`.

When a topic is archived while a topic message is pending, the BE returns `TOPIC_ARCHIVED` 410 → drop the pending item with toast `"Topic was archived — message not sent"`. Standard outbox failure handling otherwise.

### 4.3 `ConversationsCache` — extension

Add a method `patchLastMessage(conversationId: String, text: String?, at: String?, sender: String?)` used by the SocketClient when handling `topic:message` (see §2.4.1). No new state; just a setter on the existing per-conversation row that the list view already binds to.

---

## 5. Navigation & deep linking

No router changes in v1. Push notification routing for topic messages uses the existing parent-conversation route: a push fired from a topic message lands on `AppRouter.openConversation(parentId)`, which renders `ChatDetailView(conversation: parent)`, which auto-resolves to the General topic. The user can switch to the originating topic via the sheet.

A v2 follow-up will add a `topic_id` field to push payloads and an `AppRouter.openTopic` helper so push lands directly on the originating topic. This requires a BE push payload change and is out of v1 scope.

---

## 6. Edge cases & failure modes

### 6.1 Per-event behavior matrix

| Case | Client behavior |
|---|---|
| `topicsEnabled=true` but `fetchTopics` returns empty | Fall back to `.conversation(parent)` and log a warning. BE invariant says General is auto-created when topics first enabled, so this only happens in race / soft-fail conditions. |
| `topic:settings-updated` with `topicsEnabled=false` while sheet open | Dismiss sheet, switch active target to `.conversation(parent)`, toast `"Topics disabled by admin"`. |
| Active topic gets archived | Toast `"This topic was archived"`. ChatViewModel switches to General if still available, otherwise to `.conversation(parent)`. Mirrors extension Bug 8. |
| Send into closed topic (`TOPIC_CLOSED` 403) | Toast `"This topic is closed — only admins can post"`. Outbox item dropped. v1 has no closed-state badge in the row (deferred). |
| Send into archived topic (race) | Toast `"Topic was archived — message not sent"`. Outbox dropped. |
| Create topic — rate limit (`TOPIC_RATE_LIMIT` 429) | Toast `"You're creating topics too fast"`. Form stays open. |
| Create topic — duplicate name (`TOPIC_NAME_TAKEN` 409) | Inline error under the name field: `"Name already in use"`. Form stays open. |
| Create topic — forbidden (`TOPIC_FORBIDDEN` 403) | Toast `"Only admins can create topics here"`. Form dismisses. |
| Pin slot taken (`TOPIC_PIN_ORDER_TAKEN` 409) | Toast `"Pin slot already taken — choose another"`. List unchanged. |
| Pin limit hit (`TOPIC_PIN_LIMIT` 400) | Toast `"Maximum 5 pinned topics — unpin one first"`. |
| WS reconnect | Re-fetch topic list for any parent that has a mounted sheet or an active ChatViewModel target. Diff against `TopicListStore`, apply additions/updates/removals. |
| Push notification from a topic message | Lands on parent → resolves to General topic. User switches to source topic via sheet. (v2: deep-link to source topic.) |
| iPad / Catalyst | `.sheet` renders as a floating panel automatically. No platform-specific code needed; verify the drag indicator and detents render. |
| Dark mode | `TopicColor*.colorset` assets define light/dark variants; semantic foreground colors (`.primary`, `.secondary`, `.tertiary`) adapt automatically. |

### 6.2 BE aggregation verified — parent `last_message_at`

Verified in `gitchat-webapp/backend/src/modules/messages/services/messages.service.ts:1300–1317`:

```ts
// Auto-accept message request when recipient replies. When the target is
// a topic, also bump the parent row so legacy clients (VS Code extension,
// mobile app) see fresh activity on the single inbox entry they render.
const convIdsToBump = topicParentId !== null
  ? [effectiveConversation.id, topicParentId]
  : [effectiveConversation.id];
await this.messageConversationRepository
  .createQueryBuilder()
  .update()
  .set({ lastMessageText: previewText, lastMessageAt: () => 'NOW()',
         lastSenderLogin: login, ... })
  .where('id IN (:...ids)', { ids: convIdsToBump })
  .execute();
```

**Implication:** the iOS conversation list does not need to compute aggregated activity — the BE already does. The iOS `topic:message` handler still patches the parent row locally to avoid a REST round-trip while the user has the app open (§2.4.1), but stale data on cold start is impossible.

### 6.3 Permission UX (a3 path)

iOS does not track conversation roles in v1. Pin / Unpin / Archive context-menu items are shown to every user; the BE returns 403 with a typed error code when the user lacks permission, and the iOS error handler converts the code into a toast message. This mirrors how the existing app handles delete-message and pin-message (BE-enforced). Trade-off: a non-admin discovers their lack of permission only when they try the action. Acceptable for v1 — a settings panel with role-aware UI is a planned follow-up.

---

## 7. Files to create / modify

### 7.1 New files (10)

| Path | Purpose |
|---|---|
| `GitchatIOS/Core/UI/TopicColor.swift` | `TopicColorToken` enum + asset resolution |
| `GitchatIOS/Core/Networking/APIClient+Topic.swift` | All v1 topic endpoints |
| `GitchatIOS/Features/Conversations/Topics/TopicListStore.swift` | Observable per-parent topic cache |
| `GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift` | Bottom-sheet topic list |
| `GitchatIOS/Features/Conversations/Topics/TopicRow.swift` | Row component |
| `GitchatIOS/Features/Conversations/Topics/TopicCreateSheet.swift` | Create form |
| `GitchatIOS/Features/Conversations/Topics/TopicEmojiPresets.swift` | The 12 preset emojis |
| `GitchatIOS/Resources/Assets.xcassets/TopicColorRed.colorset/` | + 7 more colorsets (Orange / Yellow / Green / Cyan / Blue / Purple / Pink), each with light + dark variants |
| `docs/superpowers/specs/2026-04-28-ios-topic-feature-design.md` | This spec |
| `docs/superpowers/plans/2026-04-28-ios-topic-feature-plan.md` | Implementation plan (created later by `superpowers:writing-plans`) |

### 7.2 Modified files (7)

| Path | Change |
|---|---|
| `GitchatIOS/Core/Models/Models.swift` | Add `Topic` struct, `ChatTarget` enum, `topics_enabled: Bool?` on `Conversation` |
| `GitchatIOS/Core/OutboxStore.swift` | Add `topic_id: String?` on `OutboxItem`, branch endpoint resolution |
| `GitchatIOS/Core/Realtime/SocketClient.swift` | Subscribe + handle 7 topic events; dedup `message:sent` vs `topic:message` |
| `GitchatIOS/Features/Conversations/ConversationsCache.swift` | `patchLastMessage(...)` setter |
| `GitchatIOS/Features/Conversations/ChatDetailView.swift` | Lazy target resolution, sheet hosting |
| `GitchatIOS/Features/Conversations/ChatDetail/ChatDetailTitleBar.swift` | Emoji + name, parent subtitle, chevron, tap to open sheet |
| `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift` | `init(target:)`, `switch(to:)`, branched send/fetch endpoints |

After creating new files, run `xcodegen generate` to refresh `GitchatIOS.xcodeproj/project.pbxproj`. Do not hand-edit the pbxproj.

---

## 8. Test plan

### 8.1 Unit tests

The repo currently has only `GitchatIOSUITests` (UI tests, declared in `project.yml:244`). Pure-logic tests for `Topic` decode, `ChatTarget` resolution, `TopicListStore.applyEvent`, and `TopicColorToken.resolve` belong in a unit-test target — not the UI test target. **Add a new `GitchatIOSTests` target** in `project.yml` (XCTest, no host app) and re-run `xcodegen generate`. Place the test files under `GitchatIOSTests/`.

- `Topic` decode against representative BE JSON fixtures: with/without `icon_emoji`, with/without `color_token`, archived, pinned (each pin order 1–5), `is_general=true`.
- `ChatTarget.conversationId` and `parentConversationId` correctness for both cases.
- `ChatViewModel.sendEndpoint` returns the correct URL pattern for `.conversation` and `.topic` targets.
- `TopicListStore.applyEvent` for `topic:created`, `topic:archived`, `topic:pinned`, `topic:unpinned`, `topic:updated`, `topic:settings-updated` — verify resulting state and sort order.
- `TopicColorToken.resolve("blue")` returns `.blue`; unknown token returns `.blue` (default).

### 8.2 Manual test plan

**Setup:** a group `test-topics` with `topicsEnabled=true`, General + 2 other topics, two test users (one admin, one member).

1. Member: tap group row → lands on General topic; header shows `"💬 General"` + subtitle `"in test-topics"` with chevron.
2. Member: tap header → bottom sheet opens with drag handle, "Topics" title, parent group subtitle, list including General + 2 other topics, plus the `+` button.
3. Member: tap a non-active topic in sheet → header swaps, messages reload, sheet dismisses.
4. Member: tap `+` → create sheet opens at medium detent; type `"Bug Reports"`, choose 🐛, choose red, tap Create; toast `"Topic created"`; create sheet dismisses; new row visible in list sheet.
5. Admin (different device): receives `topic:created` over WS; their list animates the new row in.
6. Admin: long-press `Bug Reports` → context menu; pick `Pin to 1`; row jumps into Pinned section; Member device receives `topic:pinned`, list re-orders.
7. Admin: long-press → Archive; row vanishes; Member, if currently viewing that topic, sees toast `"This topic was archived"` and is moved to General.
8. Member: tap `+` four times in rapid succession → on the fourth, toast `"You're creating topics too fast"`; form stays open.
9. Member: long-press a topic → tap Pin to 1 → toast `"Only admins can pin topics"` (BE 403 path).
10. Both devices: send messages back and forth in a topic; messages render inline; the *other* device receiving while outside the topic sees the topic's unread badge bump in the sheet without manually refreshing.
11. Toggle airplane mode for ~5 seconds → reconnect → topic list re-syncs; no events missed.
12. Switch to a non-topics group → header has no chevron; tapping the header has no effect; no sheet button appears.
13. Catalyst: `TopicListSheet` renders as a floating panel, drag-to-dismiss works, drag indicator visible.

### 8.3 CI

- `xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'generic/platform=iOS' -allowProvisioningUpdates build` passes.
- Existing UI tests do not regress. The `ChatViewModel` signature refactor is the highest-risk change — a smoke test that opens an existing DM and renders one inbound message should be a hard gate.

---

## 9. Open follow-ups (v2+ candidates)

- Rename / recolor / unarchive / delete / close / reopen / hide-general / per-user permissions UI.
- Settings panel for admins (enable topics, creation mode toggle).
- Search bar inside `TopicListSheet`.
- Conversation role tracking on the client (enables hiding admin-only actions instead of toast-after-403).
- Optimistic insert on topic create.
- Push payload `topic_id` field + deep-link `gitchat://topic/:id`.
- Visual indicator (badge / dot) on parent group row in `ConversationsListView` to hint that topics are enabled.
- Closed / archived badge on topic rows.
- Drag-to-reorder pin order in the list (alternative to the long-press → pin to slot N flow).

---

## 10. Risks (mitigations inline)

| Risk | Mitigation |
|---|---|
| BE may not yet broadcast every event we listen for (e.g. `topic:settings-updated`) | Defensive subscribers — unknown events are logged and ignored; reconnect re-fetch will catch missed state. Smoke-test against staging before ship. |
| `ChatViewModel` signature refactor risks regressing existing chat behavior | Land in two commits: (1) `ChatTarget` + signature change with no behavioral diff, (2) topic logic on top. UI tests gate the refactor commit. |
| `topic:message` and `message:sent` deduplication is subtle | Spec'd explicitly (§2.4.1). Add a dedicated unit test that asserts the same payload arriving on both events results in exactly one append. |
| iOS push payload routing leaves users on General when they expected the source topic | Document in user-facing release notes. v2 work item to add `topic_id` to push payloads (BE-side change). |
| Eight new colorsets must respect dark mode contrast | Use Apple HIG semantic palette light/dark pairs — these are pre-tested for AA contrast. Capture screenshots in the PR. |
