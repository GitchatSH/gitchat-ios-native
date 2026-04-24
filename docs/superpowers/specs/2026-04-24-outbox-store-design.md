# Outbox Store — fix for issue #60 (iOS message-loss on rapid back-nav)

**Status:** Pending user review
**Author:** Ethan
**Date:** 2026-04-24
**Issue:** [GitchatSH/gitchat-ios-native#60](https://github.com/GitchatSH/gitchat-ios-native/issues/60)
**Scope:** iOS-only. No backend, socket protocol, or extension changes.

## Problem (recap)

When a user taps **Send** in a chat and immediately backs out, the optimistic
bubble disappears on re-entry — sometimes for several seconds — before the
real server message reappears. The message is never actually lost on the
server, but the perception of data loss erodes trust.

Root cause (verified against current code):

1. `ChatViewModel` is owned by `ChatDetailView` as `@StateObject`. Optimistic
   message lives in `vm.messages` (`ChatViewModel.swift:229`).
2. The send Task is `Task { await vm.send() }` — unstructured, so it is *not*
   auto-cancelled on view dismiss. It captures `vm` strongly, so `vm` survives
   until the Task completes. **But** the mutation (`messages[idx] = msg` at
   line 242) lands on a `vm` that no longer drives any visible view.
3. `MessageCache` is only persisted from inside `load()`
   (`ChatViewModel.swift:112, 133`). The optimistic insert is **never** written
   to disk.
4. On re-entry, a fresh `ChatViewModel` is constructed. Its `init` reads
   `MessageCache.shared.get(...)` (`ChatViewModel.swift:33`), which has the
   pre-send snapshot — no optimistic bubble. Then `load()` fetches from the
   API; depending on whether the BE row is committed/replicated, the message
   may be missing in the response.
5. The socket `MESSAGE_SENT` event eventually arrives and the new `vm` appends
   the message via `socket.onMessageSent` (`ChatDetailView.swift:711`),
   producing the "magically reappears" symptom.

The backend always commits and emits — that path is correct. The fix is
client-side only.

## Goal

The user must never see a sent bubble disappear due to view lifecycle. A sent
message stays visible (with a "sending" or "failed" indicator) until either:
- the server confirms it (bubble swaps to the server message), or
- the user explicitly discards it.

Acceptance criteria (per issue, scope B):
- [ ] AC1 — Quickly exiting a chat after tapping send does NOT cause the
  just-sent bubble to disappear on re-entry.
- [ ] AC2 — In-flight `sendMessage` work is NOT cancelled when
  `ChatDetailView` is dismissed.
- [ ] AC3 — Pending state persists across view dismissal + re-entry within
  the same app session.
- [ ] AC5 — Failed sends show Retry / Discard affordance; Retry re-queues
  without retyping.
- [ ] AC6 — No duplicate-id crash on the diffable data source when the server
  message arrives while a pending row is in the list.

AC4 (subtle "sending" indicator) and AC7 (extension parity verification) from
the issue are partially or out of scope:
- AC4 — bubble shows pending state via existing `local-` rendering; an
  explicit spinner polish pass is deferred to a design iteration.
- AC7 — separate task for the extension team; tracked in the issue.

Other out of scope (deferred to follow-up issues):
- Persistent outbox across app kill/relaunch (issue's "Out of scope" §1).
- Image upload path (`uploadImagesAndSend`) — overlaps with issue #58.
- Edit-message path — different lifecycle, not affected by this bug.

## Architecture

```
┌─────────────────┐         enqueue / markDelivered /
│  ChatViewModel  │────────►  markFailed / retry / remove
│  (per-view)     │              │
└────────┬────────┘              ▼
         │ visibleMessages ┌──────────────────┐
         │ (computed)      │  OutboxStore     │ ◄── @MainActor singleton,
         │                 │  .shared         │     lives for app session
         │  reads          │                  │
         └────────────────►│  pending: [      │
                           │   convId :       │
                           │   [PendingMsg]   │
                           │  ]               │
                           └────────┬─────────┘
                                    │ @Published → ObjectWillChange
                                    ▼
                           ChatView re-renders
```

Key invariants:
- `OutboxStore` lifetime ≥ any `ChatViewModel` instance.
- Pending messages live **only** in `OutboxStore` — never in `vm.messages`.
- Server-confirmed messages live **only** in `vm.messages` — never in outbox.
- Render-time merge (`vm.visibleMessages`) is the only place the two
  collections combine, eliminating the duplicate-id crash surface.

## Components

### New: `GitchatIOS/Core/OutboxStore.swift`

```swift
@MainActor
final class OutboxStore: ObservableObject {
    static let shared = OutboxStore()
    private init() {}

    struct PendingMessage: Identifiable, Equatable {
        let localID: String          // "local-<UUID>"
        let conversationID: String
        let senderLogin: String
        let senderAvatar: String?
        let content: String
        let replyToID: String?
        let createdAt: Date
        var state: State

        enum State: Equatable {
            case sending
            case failed(message: String)
        }

        var id: String { localID }
    }

    @Published private(set) var pending: [String: [PendingMessage]] = [:]

    func enqueue(_ msg: PendingMessage)
    func markDelivered(conversationID: String, localID: String)
    func markFailed(conversationID: String, localID: String, error: String)
    func remove(conversationID: String, localID: String)
    func retry(_ pending: PendingMessage)              // flips state, re-fires Task.detached
    func pendingFor(_ conversationID: String) -> [PendingMessage]
    func toMessage(_ p: PendingMessage) -> Message    // adapt to existing Message type
}
```

Notes:
- `@Published` triggers `ObservableObject` notifications on every mutation;
  any `ChatView` observing the singleton re-renders.
- `retry()` internally re-uses the same send pipeline (sends through
  `APIClient.shared.sendMessage`), so retries get the same delivered/failed
  treatment as first sends.

### Modified: `ChatViewModel.swift`

#### `send()` (replace `else { ... }` at lines 211–250)

```swift
} else {
    let pending = OutboxStore.PendingMessage(
        localID: "local-\(UUID().uuidString)",
        conversationID: conversation.id,
        senderLogin: AuthStore.shared.login ?? "me",
        senderAvatar: nil,
        content: body,
        replyToID: replyId,
        createdAt: Date(),
        state: .sending
    )
    OutboxStore.shared.enqueue(pending)
    Haptics.impact(.light)

    let convId = conversation.id
    let localID = pending.localID
    let messageBody = pending.content
    let replyTo = pending.replyToID
    Task.detached(priority: .userInitiated) {
        do {
            let msg = try await APIClient.shared.sendMessage(
                conversationId: convId, body: messageBody, replyTo: replyTo
            )
            await MainActor.run {
                ChatMessageView.seenIds.insert(msg.id)
                OutboxStore.shared.markDelivered(
                    conversationID: convId, localID: localID
                )
                // Server message arrival into vm.messages happens via:
                //  (a) socket onMessageSent (already wired, ChatDetailView:711), or
                //  (b) next vm.load() on re-entry.
                // No direct mutation of vm.messages here — vm may be dead.
            }
        } catch {
            await MainActor.run {
                OutboxStore.shared.markFailed(
                    conversationID: convId, localID: localID,
                    error: error.localizedDescription
                )
            }
        }
    }
}
```

#### `visibleMessages` (new computed property)

```swift
var visibleMessages: [Message] {
    let pending = OutboxStore.shared.pendingFor(conversation.id)
        .map(OutboxStore.shared.toMessage)
    return (messages + pending).sorted { $0.created_at < $1.created_at }
}
```

`messages` already comes back ascending by `created_at` from `load()` (via
`resp.messages.reversed()`). Pending messages are appended with `Date()` at
enqueue time, which is always ≥ the latest server message the user could see
at that moment.

### Modified: `ChatView.swift`

- Add `@ObservedObject private var outbox = OutboxStore.shared` at the top of
  `ChatView` (and any sibling subview that renders the message list directly).
- Replace every read of `vm.messages` *inside the message list rendering path*
  with `vm.visibleMessages`. Reads outside that path (e.g., search, pinned
  list, scroll-to-message) keep using `vm.messages` because those operate on
  server-confirmed messages only.
- Long-press menu (`MessageMenuAction`): when `message.id.hasPrefix("local-")`,
  resolve the corresponding pending entry from `OutboxStore` and show:
  - if `.sending` → no menu (gesture is a no-op while in flight)
  - if `.failed` → **Retry** + **Discard**
- Tap on the red `!` icon on a failed bubble → same Retry/Discard menu
  (faster path).

### Modified: `ChatDetailView.swift`

- `socket.onMessageSent` handler at lines 711–724 — simplify:
  - Drop the `firstIndex(where: { $0.id.hasPrefix("local-") && ... })` swap
    branch. Pending bubbles no longer live in `vm.messages`, so this branch
    can never match.
  - Keep the `vm.messages.contains(where: { $0.id == msg.id })` dedup guard.
  - Keep `vm.messages.append(msg)` for the not-already-present case.
  - Keep the `markRead` for non-self senders.

## Data flow

### Happy path — user stays in chat

1. Tap send → `OutboxStore.enqueue(pending: .sending)` → `visibleMessages`
   includes pending → bubble visible.
2. `Task.detached` calls `APIClient.sendMessage`.
3. BE INSERT → BE emit `MESSAGE_SENT` over socket.
4. (a) Socket `MESSAGE_SENT` arrives → `vm.messages.append(msg)`.
5. (b) HTTP response returns → `markDelivered` → pending removed.
6. `visibleMessages` now contains the server message; pending gone. No
   duplicate, no flicker (single source of truth per state).

### Bug-trigger path — user backs out before response

1. Tap send → enqueue pending → bubble visible.
2. User taps back → `ChatDetailView` dismisses, `vm` ref-counted only by the
   detached Task; no view observing it. **`OutboxStore.shared` still alive.**
3. Detached Task continues; HTTP response returns; `markDelivered` removes
   pending from outbox. Socket `MESSAGE_SENT` is broadcast but no
   `ChatDetailView` for this conversation is mounted to receive it.
4. User re-enters conversation → fresh `ChatDetailView` → fresh
   `ChatViewModel`. `init` reads `MessageCache` (still stale).
5. `load()` fires → GET `/messages` → server message present (BE long since
   committed) → `vm.messages` includes it → bubble visible.
6. If outbox somehow still has the pending (race where re-entry happens
   before `markDelivered`), `visibleMessages` shows pending too — but
   `markDelivered` always runs from `Task.detached`, which is independent of
   view lifecycle, so it always runs and the pending is cleared shortly
   after.

### Failed path — network error

1. Enqueue pending → bubble visible.
2. `APIClient.sendMessage` throws → `markFailed(error)` → bubble re-renders
   with `!` icon.
3. User long-presses (or taps `!`) → menu: Retry / Discard.
4. Retry → `OutboxStore.retry(pending)` → state flips back to `.sending` →
   new `Task.detached` runs the send.
5. Discard → `OutboxStore.remove(...)` → bubble vanishes.

### Cross-conversation isolation

- Outbox keyed by `conversationID`. Pending in conversation A do not appear
  in conversation B's `visibleMessages`. Verified by unit test.

## Error handling

- `APIClient.sendMessage` errors propagate into `markFailed(error:)` with the
  error's `localizedDescription`. UI shows this string in the toast on first
  attempt (existing `ToastCenter` flow) and as the failure reason in the
  Retry/Discard menu subtitle.
- `OutboxStore` mutations are `@MainActor`; no cross-thread races.
- If `Task.detached` is cancelled (e.g., app suspend → kill), pending stays
  in `.sending`. On next app launch, outbox is empty (in-memory only); the
  message is lost client-side. BE may still have committed it — next
  `load()` will surface it normally. (Out-of-scope for this iteration; see
  issue's persistent-outbox § for follow-up.)

## Testing

### Unit tests (XCTest)

Target file: `GitchatIOSTests/OutboxStoreTests.swift` (new)

- `test_enqueue_addsToCorrectConversation` — enqueue in conv A; pendingFor(B)
  returns empty.
- `test_markDelivered_removesPending` — enqueue → markDelivered → pendingFor
  returns empty.
- `test_markFailed_setsFailedState` — enqueue → markFailed → state == .failed.
- `test_retry_flipsStateBackToSending` — markFailed → retry → state == .sending.
- `test_remove_clearsPending` — enqueue → remove → pendingFor returns empty.
- `test_publishedFires_onEachMutation` — observe `pending` `@Published`,
  count emissions across all mutator calls.

Target file: `GitchatIOSTests/ChatViewModelVisibleMessagesTests.swift` (new)

- `test_visibleMessages_mergesServerAndPending` — given vm.messages = [A, C]
  and outbox pending [B] (B between A and C by createdAt), visibleMessages
  returns [A, B, C].
- `test_visibleMessages_emptyWhenNoServerNoPending` — returns [].
- `test_visibleMessages_excludesOtherConversationsPending` — outbox has
  pending in conv X; vm for conv Y returns only its own server messages.

### Manual scenarios (simulator)

Run on the booted iOS 26.4 / iPhone 17 simulator with API at
`http://localhost:3000`.

1. **AC1 — Happy back-nav**: send a message, immediately tap back, wait 2s,
   re-enter the chat. Bubble must remain visible the entire time. Expected:
   pending bubble while in chat → real message after re-entry, no flicker
   gap.
2. **AC5 — Retry**: stop the API server, send a message, observe failed
   bubble with `!`. Long-press → Retry. Restart API. Observe send completes,
   bubble swaps to server message.
3. **AC5 — Discard**: same setup as Retry, but choose Discard. Bubble
   vanishes; restart API; nothing reappears (the message was never sent
   server-side).
4. **Cross-conversation**: with API stopped, send in conv A → back → send
   in conv B → back → re-open A. A's failed bubble visible; B's failed
   bubble visible only in B. Restart API; retry both; both succeed
   independently.
5. **AC6 — No crash on dup**: send a normal message while staying in chat,
   observe socket `MESSAGE_SENT` arrives within ~50ms of HTTP response. No
   diffable-data-source crash.

### Backend

No backend changes; no backend tests affected.

## Migration / rollout

- Pure additive iOS code change. No data migration, no user-facing setting,
  no protocol bump.
- Ship behind no flag — change is small enough that it is safer to land as
  one PR than to gate.
- App version bump per existing release process; surface in TestFlight
  release notes as "Reliability: messages no longer disappear if you back
  out of a chat right after sending".

## Risks

- **Flicker on Case B race** (HTTP response arrives before socket): outbox
  pending is removed before `vm.messages` has the server msg, leaving a
  ~10–100ms gap. Mitigation: ship as-is and watch QA. If perceptible,
  follow-up patch makes pending state `.delivered(serverID)` and have
  `visibleMessages` filter by "pending hidden iff serverID present in
  vm.messages". Documented as a known minor follow-up, not blocking.
- **All callers updated**: any place that reads `vm.messages` for rendering
  (vs. for non-render logic like search) must switch to `visibleMessages`.
  The implementation plan must inventory every read site and audit each.
- **Long-press menu logic**: `MessageMenuAction` builder must early-return a
  reduced action set for `local-` IDs. Risk: a forgotten action (Reply,
  React, Forward, Pin) on a pending message would crash or hit a 404.
  Implementation must defensively map all menu actions through this gate.

## References

- Issue: GitchatSH/gitchat-ios-native#60
- Current send pipeline: `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift:211-250`
- View ownership: `GitchatIOS/Features/Conversations/ChatDetailView.swift:22, 75, 154`
- Cache write surface: `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift:112, 133, 138`
- Backend send (unchanged): `gitchat-webapp/backend/src/modules/messages/services/messages.service.ts:1108-1402`
- Extension parity (why extension is unaffected):
  `gitchat_extension/src/webviews/chat.ts:134` (`retainContextWhenHidden: true`)
