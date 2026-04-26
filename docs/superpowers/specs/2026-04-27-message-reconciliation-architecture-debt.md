# Message Reconciliation Architecture Debt

**Date:** 2026-04-27
**Status:** Discovered during paste-image-clipboard task. Fix deferred to dedicated task.
**Owner:** TBD (handoff to whoever picks up message-pipeline architectural work)

## Context

The paste-image-clipboard task (spec `2026-04-26-paste-image-from-clipboard-design.md`,
plan `2026-04-26-paste-image-from-clipboard.md`) intentionally reused the existing
drop pipeline. Stress-testing the paste flow on iPhone Simulator + Mac Catalyst
exposed five distinct bugs in the shared message-reconciliation pipeline. Four
of the five predate the paste task; only the surface symptoms changed. This doc
records what was found, what was patched in-branch, and what remains unfixed.

## Symptoms observed

| # | Symptom | Status in `feat/paste-image-clipboard` | Pre-existing? |
|---|---|---|---|
| 1 | UIDiffableDataSource crashes with `NSInternalInconsistencyException` "supplied item identifiers are not unique" when sender's WebSocket delivery races the HTTP send response | **Patched** in commit `e734137` — HTTP handlers now honor the existing `seenIds` dedupe contract that WebSocket and OutboxStore handlers already follow | Yes — crash report `Gitchat-2026-04-27-003353.ips` predates this branch's first commit |
| 2 | Sender's chat view leaves stuck `local-*` optimistic bubbles (spinner forever) after back-out + re-enter when the back-out happened mid-upload | **Not patched** | Yes — independent of paste flow |
| 3 | Receiver-side message order can differ from sender-side ordering for "text + image" sends because the two `Task` calls in `sendDroppedImages` race | **Not patched** (the bundling-into-one-message fix `a8f62c2` was reverted to `3782128` because it exposed bug #1 more frequently and the spec marked single-message bundling as a Non-goal) | Yes |
| 4 | `socket.onMessageSent` callback may run on a non-main queue while it mutates `vm.messages` (a `@MainActor`-isolated `@Published` property) | **Unverified** — flagged during investigation, not confirmed by reading `SocketClient.swift`'s dispatch context fully | Yes |
| 5 | `MessageCache` blindly persists `messages` including any `local-*` optimistic entries, so subsequent vm inits read those leaked entries from disk and `vm.load()`'s merge logic never cleans them up (it only matches/replaces by id, and `local-*` ids never match server ids) | **Not patched** | Yes |

## Why the existing architecture is fragile

The `messages` array is a single shared mutable list. The following actors all
mutate it, with different consistency guarantees:

- `ChatViewModel.send()` (text-only) → enqueues into `OutboxStore`, which later
  emits via `deliveryHandlers[convId]?(stamped)` registered by `ChatDetailView`
- `ChatViewModel.uploadImagesAndSend()` / `uploadAndSend()` (image flows) →
  appends an optimistic placeholder, awaits HTTP, then either replaces the
  optimistic with the server `Message` or removes it (post-`e734137` patch)
- `socket.onMessageSent` (WebSocket delivery handler in `ChatDetailView`) → reads
  `ChatMessageView.seenIds.insert(msg.id).inserted` and appends if first sighting
- `OutboxStore.shared.registerDeliveryHandler` callback → same dedupe contract
- `vm.load()` and `vm.loadMoreIfNeeded()` → fetch from BE, merge by id-match,
  call `persistCache()`
- `ChatViewModel.init` → reads `MessageCache.shared.get(conversation.id)` and
  rehydrates `messages` from it

`ChatMessageView.seenIds` is a static set (`nonisolated(unsafe)`) used as a
delivery dedupe key, but it is not synchronized with `messages` — they can drift
apart. The `local-*` optimistic ids exist in `messages` but never in `seenIds`
(seenIds tracks server-issued ids only), so any code that reasons about
"already-delivered" via `seenIds` is invisible to `local-*` lifecycle.

## Architectural options for the dedicated fix

Each option below should be its own brainstorming + spec cycle. Listed in
roughly increasing order of cost.

1. **Filter `local-*` at persistCache** *(narrow band-aid for symptom #5 only)*.
   One-line change in `ChatViewModel.persistCache`:
   ```swift
   messages: self.messages.filter { !$0.id.hasPrefix("local-") }
   ```
   Prevents future cache leaks, doesn't heal already-leaked caches without an
   additional `vm.load()`-merge filter. Doesn't address race conditions or
   off-main mutation.

2. **Single source of truth — make `messages.contains(where:)` the dedupe
   check, drop `seenIds`**. Avoids the seenIds-vs-messages drift entirely.
   Touches every WebSocket / OutboxStore / HTTP send call site. Medium scope.

3. **Pre-insert msg into `messages` BEFORE flipping any dedupe flag**. Reverses
   the current order. WebSocket and HTTP both check `messages.contains(msg.id)`
   first, then append. Eliminates the window where seenIds says "yes" but
   messages doesn't have it yet. Medium scope.

4. **Round-trip a `client_message_id` through `sendMessage`**. Backend includes
   it in the WS broadcast payload. Frontend dedupes optimistic↔real by
   `client_message_id` instead of trying to coordinate two separate ids.
   Eliminates the entire local-vs-server id mismatch problem. Requires backend
   change. Largest scope, cleanest result.

5. **Atomic critical section per conversation**. Wrap mutate operations on
   `messages` and `seenIds` in a `private actor` or `NSLock`. Forces all writes
   serial. Doesn't address the wrong-id-shape problem (option 4) but does
   eliminate races. Medium scope.

## Out of scope for paste-image-clipboard

The paste task ships with bugs #2, #3, #4, #5 unaddressed. Bug #1 is patched
because it was a hard crash blocking the paste flow itself. The patch follows
the architecture's existing `seenIds` contract — it is not a band-aid; it just
makes the HTTP handlers symmetric with the two other handlers that already
implemented the contract correctly.

The paste flow's golden path (open chat → Cmd+V → sheet → caption + send →
both sides see the message) works correctly. The known failure modes are:

- Stress-test scenarios with many sends in a few seconds (raises bug #1's
  pre-patch probability — now caught by the `seenIds.inserted` branch)
- Back-out + re-enter mid-upload (leaves stuck optimistic per bug #5)
- Image+text sent together (different display order between sender and
  receiver per bug #3)

Mention these in the PR description so reviewers / users know what's not yet
fixed.

## References

- Spec: `docs/superpowers/specs/2026-04-26-paste-image-from-clipboard-design.md`
- Plan: `docs/superpowers/plans/2026-04-26-paste-image-from-clipboard.md`
- Crash report (bug #1, pre-existing): `~/Library/Logs/DiagnosticReports/Gitchat-2026-04-27-003353.ips`
- Bug #1 patch: commit `e734137` ("fix(ios): honor seenIds dedupe contract in
  HTTP send handlers")
- Reverted bundling fix (would have made bug #1 worse): commits `a8f62c2`
  (apply) → `3782128` (revert)
