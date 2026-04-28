# Optimistic Send Pipeline

How a tap on **Send** in a chat travels from the composer to a confirmed
server bubble — and why the architecture is shaped the way it is.

> **If you are about to modify any code in this pipeline**, read the
> "Invariants" section below first. Several of the rules here protect
> against bugs we've already shipped and reverted at least once.

## Why this exists

A "send a message" operation is **asynchronous and slow** (network
latency, retries, possibly seconds). The user can navigate away from the
chat at any moment. Three things must keep working under all of:

1. User taps Send and stays in the chat → bubble appears, then becomes
   server-confirmed.
2. User taps Send and **immediately backs out** → message must still
   reach the server, and the bubble must reappear when the user re-opens
   the chat.
3. User taps Send several times in quick succession → bubbles must
   appear in tap order, none missing, none duplicated, none jittering
   into a different position after the fact.

Issue [#60](https://github.com/GitchatSH/gitchat-ios-native/issues/60)
documents the original bug for case 2; PRs
[#75](https://github.com/GitchatSH/gitchat-ios-native/pull/75) and
[#79](https://github.com/GitchatSH/gitchat-ios-native/pull/79) implement
and refine this pipeline.

## High-level architecture

```
┌────────────────────┐                 ┌──────────────────────────────┐
│  ChatView          │   visibleMsgs   │  OutboxStore.shared          │
│  (per screen,      │ ◄────────────── │  (singleton, app-lifetime)   │
│   sized + dies)    │                 │                              │
│                    │   register/     │  pending: [convId: [Pending]]│
│                    │   unregister    │  sendChain: [convId: Task]   │
│                    │ ──────────────► │  deliveryHandlers: [convId: ]│
└─────────┬──────────┘                 │                              │
          │                            │  enqueue / runSend /         │
          │ tap Send                   │  markDelivered / markFailed /│
          │                            │  retry / discard             │
          ▼                            └──────────┬───────────────────┘
┌────────────────────┐                            │
│  ChatViewModel     │ ──── enqueue ─────────────►│
│  (per screen,      │ ──── runSend ─────────────►│
│   @StateObject)    │                            │
│                    │                            │  per-conv FIFO chain:
│  vm.messages       │ ◄── handler(server msg) ───│  Task.append → await prev
│  vm.visibleMessages│                            │                ↓
│  = messages ∪      │                            │            HTTP →
│    pending(conv)   │                            │            success →
└────────────────────┘                            │              markDelivered
                                                  │              + handler(stamped)
```

Three layers, three lifetimes:

| Layer | Lifetime | Owns |
|---|---|---|
| `ChatView` | per screen visit (dies on back-nav) | UI state: scroll, focus, menu overlay |
| `ChatViewModel` | per `ChatView` (`@StateObject`) | Per-conversation **server-confirmed** messages, draft, typing indicator, pinned ids |
| `OutboxStore.shared` | App session (singleton) | **Pending** sends across all conversations, send queues, delivery callbacks |

Render-time merge happens in **one place only**:
`ChatViewModel.visibleMessages` returns `messages + outbox.pendingFor(conv)`,
sorted by `created_at`. Both `ChatView` and `ChatDetailView` read this.

## Invariants (these are not negotiable)

Each of these encodes a bug that broke at least once. Don't relax any
without understanding what fails:

1. **Pending lives ONLY in `OutboxStore.pending`.** Server-confirmed
   messages live ONLY in `vm.messages`. They are merged at render-time.
   Never insert a `local-`-prefixed id into `vm.messages`. Never insert a
   server id into `OutboxStore.pending`.

2. **Sends serialize per conversation, parallelize across.**
   `OutboxStore.runSend(for:)` chains each send via `sendChain[convId]`
   so the BE INSERT order matches the user's tap order. Don't fire HTTP
   directly — always go through `runSend`.

3. **HTTP success appends to `vm.messages` via the registered delivery
   handler, NOT via the WebSocket alone.** The socket can be slow,
   disconnected, or (in local dev) entirely absent. Relying on it means
   the user's own bubble vanishes. The handler is the primary path; the
   socket is the secondary path for OTHER users' messages and for
   redundancy on our own.

4. **Pre-stamp the server message with the pending's `createdAt`
   (client tap time) before invoking the handler.** This keeps the
   bubble in its typed-order position when transitioning pending →
   server-confirmed. BE INSERT time is hundreds of ms later than client
   tap time and would otherwise cause the bubble to "jump".

5. **Use millisecond precision (`.withFractionalSeconds`) for any
   `created_at` we generate locally.** The BE returns ms-precision; if
   ours is sec-precision, lex sort breaks at the `.` vs `Z` boundary
   and bubbles render in the wrong order at the same second.

6. **Do NOT touch `ChatMessageView.seenIds` from inside `executeSend`'s
   success path.** The handler uses `seenIds.insert(...).inserted` as
   its dedup signal; pre-inserting from anywhere else makes the handler
   silently no-op and the bubble never renders.

7. **Per-conversation handler registration is `register` on appear /
   `unregister` on disappear**, set up in `ChatDetailView.onAppearTask`
   / `onDisappearCleanup`. If a delivery lands while no handler is
   registered (user backed out), it's a no-op — the next `vm.load()`
   on re-entry will fetch the message from the BE.

## Code map

| File | Role |
|---|---|
| `GitchatIOS/Core/OutboxStore.swift` | Singleton store. PendingMessage struct. enqueue / markDelivered / markFailed / discard / retry. `runSend` (FIFO chain) → `executeSend` (HTTP + stamp + delivery). Handler registry. |
| `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift` | `send()` builds a `PendingMessage`, enqueues it, calls `OutboxStore.shared.runSend`. `visibleMessages` computed = `messages + pending.map(toMessage) sorted`. |
| `GitchatIOS/Features/Conversations/ChatDetailView.swift` | Owns the `ChatViewModel` as `@StateObject`. Observes `OutboxStore.shared` so re-render fires on outbox changes. `onAppearTask` registers the delivery handler; `onDisappearCleanup` unregisters. Wires `Retry` / `Discard` actions. |
| `GitchatIOS/Features/Conversations/ChatDetail/ChatView.swift` | Renders `visibleMessages`. `visibleActions(for:)` returns `[]` (sending) or `[.retry, .discard]` (failed) for `local-` ids; full menu for server ids. |
| `GitchatIOS/Features/Conversations/ChatDetail/Menu/MessageMenuAction.swift` | Enum cases incl. `.retry`, `.discard`. |
| `GitchatIOS/Features/Conversations/ChatDetail/MessageCache.swift` | Per-conversation on-disk cache. Persisted only at the end of `vm.load()` — pending bubbles are NEVER in the cache. |

## Failure modes the pipeline handles

| Scenario | Behavior |
|---|---|
| Network failure on first attempt | `markFailed` → bubble stays in store with `.failed` state → user gets toast + bubble shows failure indicator |
| User long-presses a `.failed` bubble | Menu shows **Retry** (re-runs `runSend`) and **Discard** (calls `OutboxStore.discard`) only |
| User long-presses a `.sending` bubble | Menu shows **Discard** only (escape hatch for a stalled URLSession) |
| User backs out before HTTP completes | Detached chain Task continues; `markDelivered` removes pending; delivery handler is unregistered → no-op append; user re-enters → `vm.load()` fetches the message from the BE |
| WebSocket disconnected | Self-sends still appear (delivery handler path); other-user sends fall back to next `vm.load()` or socket reconnect |
| Rapid 10× tap | All 10 enqueue instantly → bubbles visible in tap order; FIFO chain processes them serially → BE INSERT order matches tap order; each server response re-stamps with client tap time → no jitter on transition |
| Same conversation race: socket arrival vs HTTP response | `seenIds.insert(...).inserted` is the atomic dedup; whichever fires first wins, the other no-ops |

## Common pitfalls (from past PRs)

- **"Just append the server msg to `vm.messages` directly from `runSend`"** — works in production with healthy WS, but `runSend` does not have a reference to vm. Reaching back to vm couples the singleton to view state and resurrects the original `#60` bug. Use the registered delivery handler.
- **"Use `Task.detached` so sends are parallel"** — breaks tap order at the BE because requests race. Use the FIFO chain.
- **"Bypass the chain because this is a one-off send"** — every send goes through the chain or the architectural guarantee is gone.
- **"Insert msg.id into `seenIds` at HTTP success so the bubble doesn't animate in"** — defeats the handler's dedup. Let the handler be the only seenIds writer for self-sends.
- **"Use `Date()` formatted with default `ISO8601DateFormatter` for pending"** — sec precision conflicts with BE's ms precision. Use the hoisted formatter that includes `.withFractionalSeconds`.

## Glossary

- **Optimistic UI** — show a UI change immediately on user action, before the server confirms. If the server fails, revert.
- **Outbox** — a place where pending sends live independently of any view, so they survive view dismissal.
- **Delivery handler** — closure registered by an active view; called by the outbox when an HTTP send succeeds, so the view can append the new server msg to its model directly without waiting for the socket.
- **Per-conversation FIFO chain** — a chain of `Task`s per conversation, each `await`-ing the previous so HTTP requests serialize within a conversation but parallelize across.
- **Server stamp** — overriding the BE's `created_at` on the server-returned `Message` with the pending's client tap time, to keep the bubble in typed-order position.
- **Same-second lex collision** — when two `created_at` strings of different precision are at the same second, lex compare can flip them ('.' = 46 < 'Z' = 90).

## References

- Issue: [GitchatSH/gitchat-ios-native#60](https://github.com/GitchatSH/gitchat-ios-native/issues/60) — original bug
- PR [#75](https://github.com/GitchatSH/gitchat-ios-native/pull/75) — initial OutboxStore implementation
- PR [#79](https://github.com/GitchatSH/gitchat-ios-native/pull/79) — fix for the three regressions surfaced after #75 (invisible self-sends, out-of-order, post-burst jitter)
- Spec: `docs/superpowers/specs/2026-04-24-outbox-store-design.md`
- Plan: `docs/superpowers/plans/2026-04-24-outbox-store-implementation.md`
