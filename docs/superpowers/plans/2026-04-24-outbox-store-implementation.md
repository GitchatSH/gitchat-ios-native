# Outbox Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop iOS messages from appearing to vanish when the user backs out of a chat right after tapping send. Move pending-send state out of the per-view `ChatViewModel` into a shared `OutboxStore` that survives view dismissal, and render pending bubbles as an overlay that merges with confirmed server messages.

**Architecture:** New `@MainActor` singleton `OutboxStore` owns pending messages keyed by `conversationID`. `ChatViewModel.send()` enqueues into the store and dispatches a `Task.detached` for the network call (so it survives the view). A new `vm.visibleMessages` computed property merges server-confirmed messages with the outbox's pending entries. `ChatView` observes the store so it re-renders on every outbox mutation. Failed sends expose Retry/Discard via the existing long-press menu and a tap-target on the failure indicator.

**Tech Stack:** Swift 5.9+, SwiftUI, Combine `@Published`, structured & unstructured `Task` concurrency.

**Spec:** `docs/superpowers/specs/2026-04-24-outbox-store-design.md`

**Branch:** `fix/issue-60-outbox-store` (already created off `main`).

**Test infrastructure note:** This project has no XCTest target (`project.yml` defines only the `GitchatIOS` app target). Adding one is out of scope for this fix. Verification is via:
- `xcodebuild` compile pass after each task (catches type errors)
- Manual scenarios on the booted simulator (UDID `9F169B14-27EF-45AE-A30C-40FC38B1E4C5`, iPhone 17 / iOS 26.4)
- API server already running at `http://localhost:3000`

A follow-up task to introduce a proper test target is recommended but not blocking.

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `GitchatIOS/Core/OutboxStore.swift` | **Create** | Singleton store of pending sends, keyed by conversationID. Owns the `PendingMessage` struct and its state machine. |
| `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift` | **Modify** | Replace optimistic-insert in `send()` with outbox enqueue + `Task.detached`. Add `visibleMessages` computed property (merge server + pending). |
| `GitchatIOS/Features/Conversations/ChatDetailView.swift` | **Modify** | Observe `OutboxStore.shared`. Update existing `private var visibleMessages` to compose with `vm.visibleMessages`. Simplify `socket.onMessageSent` swap logic. |
| `GitchatIOS/Features/Conversations/ChatDetail/Menu/MessageMenuAction.swift` | **Modify** | Add `.retry` and `.discard` cases. |
| `GitchatIOS/Features/Conversations/ChatDetail/ChatView.swift` | **Modify** | In `visibleActions(for:)`, return `[.retry, .discard]` for failed local messages. |

---

## Task 1: Create the OutboxStore skeleton

**Files:**
- Create: `GitchatIOS/Core/OutboxStore.swift`

This task creates the store in isolation. No callers exist yet, so the only verification is that the project compiles.

- [ ] **Step 1: Create the file with full implementation**

Write `GitchatIOS/Core/OutboxStore.swift`:

```swift
import Foundation
import Combine

/// Lifetime-independent store of in-flight ("pending") sends, keyed by
/// conversation id. Survives ChatDetailView dismissal so a re-entered
/// conversation continues to show its pending bubbles.
///
/// Pending messages live ONLY here. Server-confirmed messages live ONLY
/// in `ChatViewModel.messages`. They're merged at render time by
/// `ChatViewModel.visibleMessages`.
///
/// Mutations are @MainActor; consumers observing the store re-render on
/// every change via the @Published `pending` dict.
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

    /// Key: conversationID. Value: pending messages in enqueue order.
    @Published private(set) var pending: [String: [PendingMessage]] = [:]

    // MARK: - Mutators

    func enqueue(_ msg: PendingMessage) {
        pending[msg.conversationID, default: []].append(msg)
    }

    func markDelivered(conversationID: String, localID: String) {
        guard var list = pending[conversationID] else { return }
        list.removeAll { $0.localID == localID }
        if list.isEmpty {
            pending.removeValue(forKey: conversationID)
        } else {
            pending[conversationID] = list
        }
    }

    func markFailed(conversationID: String, localID: String, error: String) {
        guard var list = pending[conversationID],
              let idx = list.firstIndex(where: { $0.localID == localID }) else { return }
        list[idx].state = .failed(message: error)
        pending[conversationID] = list
    }

    func remove(conversationID: String, localID: String) {
        markDelivered(conversationID: conversationID, localID: localID)
    }

    /// Flip a failed pending back to .sending, then re-fire the network call.
    /// Caller-supplied `send` closure receives the pending and runs the
    /// transport — this keeps OutboxStore decoupled from APIClient.
    func retry(_ pendingMsg: PendingMessage,
               send: @escaping (PendingMessage) -> Void) {
        guard var list = pending[pendingMsg.conversationID],
              let idx = list.firstIndex(where: { $0.localID == pendingMsg.localID }) else { return }
        list[idx].state = .sending
        pending[pendingMsg.conversationID] = list
        send(list[idx])
    }

    // MARK: - Reads

    func pendingFor(_ conversationID: String) -> [PendingMessage] {
        pending[conversationID] ?? []
    }

    func pending(conversationID: String, localID: String) -> PendingMessage? {
        pending[conversationID]?.first(where: { $0.localID == localID })
    }

    /// Adapt a PendingMessage to the existing Message shape so the same
    /// rendering code can render both. id keeps the "local-" prefix so
    /// downstream rendering can still detect "this is a pending bubble".
    func toMessage(_ p: PendingMessage) -> Message {
        Message(
            id: p.localID,
            conversation_id: p.conversationID,
            sender: p.senderLogin,
            sender_avatar: p.senderAvatar,
            content: p.content,
            created_at: ISO8601DateFormatter().string(from: p.createdAt),
            edited_at: nil,
            reactions: nil,
            attachment_url: nil,
            type: "user",
            reply_to_id: p.replyToID
        )
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project so the new file is part of the target**

The project uses XcodeGen (`project.yml`). When a file is added under `GitchatIOS/`, the generated `GitchatIOS.xcodeproj/project.pbxproj` must be regenerated — otherwise `xcodebuild` will silently skip the new file (it'll compile everything else and report `BUILD SUCCEEDED`, but the new file is never included in the target). SourceKit will also flag the file with "Cannot find type X in scope" until the project is regenerated.

If `xcodegen` is not installed:

```bash
brew install xcodegen
```

Then from `/Users/ethanmiller/Documents/Companies/Lab3/Gitstar/gitchat-ios-native`:

```bash
xcodegen generate
```

Expected output ends with `Created project at .../GitchatIOS.xcodeproj`. Confirm `OutboxStore.swift` is now referenced in the pbxproj:

```bash
grep -c "OutboxStore" GitchatIOS.xcodeproj/project.pbxproj
```

Expected: `4` (one in PBXBuildFile, one in PBXFileReference, one in the group, one in Sources build phase).

- [ ] **Step 3: Verify the project compiles AND that OutboxStore was actually compiled**

Run from `/Users/ethanmiller/Documents/Companies/Lab3/Gitstar/gitchat-ios-native`:

```bash
xcodebuild \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=9F169B14-27EF-45AE-A30C-40FC38B1E4C5' \
  build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`. Then verify the object file exists (proves OutboxStore was actually compiled, not silently skipped):

```bash
find ~/Library/Developer/Xcode/DerivedData/GitchatIOS-* -name "OutboxStore.o" -path "*Objects-normal*" | head -1
```

Expected: a path printed. If empty, the file was NOT included in the target — go back to Step 2.

If build fails with "Cannot find 'Message' in scope", confirm `Message` is declared in `GitchatIOS/Core/Models/Models.swift:137` and that no module boundary is being crossed (it isn't — single app target). The new file should not need any imports beyond `Foundation` and `Combine`.

- [ ] **Step 4: Commit (file + regenerated project together)**

```bash
git add GitchatIOS/Core/OutboxStore.swift GitchatIOS.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(ios): add OutboxStore for view-lifetime-independent pending sends (#60)

New @MainActor singleton holding in-flight optimistic messages keyed by
conversationID. Lifetime is the app session, so a ChatViewModel that gets
torn down on back-nav doesn't take its pending messages with it.

Includes the regenerated pbxproj so xcodebuild actually includes the new
file in the target.

No callers wired yet — that lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire OutboxStore through send + render path

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift:189-257` (the `send()` function — specifically the `else { ... }` branch at lines 211-250)
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift` (add `visibleMessages` computed property after the existing `messages` properties)
- Modify: `GitchatIOS/Features/Conversations/ChatDetailView.swift:80-82` (existing `private var visibleMessages` — keep the blocked-sender filter, source from `vm.visibleMessages`)
- Modify: `GitchatIOS/Features/Conversations/ChatDetailView.swift:711-724` (socket `onMessageSent` handler — drop the `local-` prefix swap branch)
- Modify: `GitchatIOS/Features/Conversations/ChatDetailView.swift:67-68` area (add `@ObservedObject private var outbox = OutboxStore.shared`)

After this task, the bug is fixed for the happy path: rapid back + re-entry no longer makes the bubble disappear. Failed sends still vanish silently — Task 3 adds Retry/Discard.

- [ ] **Step 1: Add `visibleMessages` to ChatViewModel**

Open `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift`. After the existing `@Published var nextCursor` / `@Published var isLoadingMore` block at lines 21-22 (before `@Published var conversation`), add a comment marker. Then, **after the `init(...)` block ending at line 42**, add this computed property:

```swift
    // MARK: - Render-time merge (pending + server)

    /// Server-confirmed messages merged with currently-pending sends from
    /// the global outbox. Re-evaluated every render. Used by the message
    /// list rendering path; non-render reads (search, pinned list, scroll
    /// targeting) stay on `messages` because those operate on
    /// server-confirmed messages only.
    ///
    /// `created_at` is an ISO8601 string; lexicographic `<` sorts these
    /// chronologically.
    var visibleMessages: [Message] {
        let pending = OutboxStore.shared.pendingFor(conversation.id)
            .map(OutboxStore.shared.toMessage)
        guard !pending.isEmpty else { return messages }
        return (messages + pending).sorted {
            ($0.created_at ?? "") < ($1.created_at ?? "")
        }
    }
```

- [ ] **Step 2: Replace the `else { ... }` send branch**

In the same file, locate `func send() async` (starts around line 168). Inside it, locate the `else { ... }` branch that runs from line 211 (`} else {`) through line 251 (the closing `}` of that else, just before the catch at line 252).

Replace the entire contents of that `else` branch (everything between the `} else {` at line 211 and the `}` at line 251 — keep the `} else {` line and the closing `}` themselves) with:

```swift
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
                            conversationId: convId,
                            body: messageBody,
                            replyTo: replyTo
                        )
                        await MainActor.run {
                            ChatMessageView.seenIds.insert(msg.id)
                            OutboxStore.shared.markDelivered(
                                conversationID: convId,
                                localID: localID
                            )
                            // Server message arrives in vm.messages via:
                            //  (a) socket onMessageSent (ChatDetailView), or
                            //  (b) the next vm.load() on re-entry.
                            // No direct mutation of vm.messages here — vm
                            // may be dead if user navigated away.
                        }
                    } catch {
                        await MainActor.run {
                            OutboxStore.shared.markFailed(
                                conversationID: convId,
                                localID: localID,
                                error: error.localizedDescription
                            )
                        }
                    }
                }
```

The outer `do { ... } catch { ... }` at lines 169 / 252 stays untouched. Note the new code does not `throw` from the network path — failures are routed through `markFailed` instead, so the outer catch will only fire for synchronous errors (which there are none in the new branch). That's intentional: the toast on first-attempt failure is replaced by the persistent failed bubble + Retry UX in Task 3.

- [ ] **Step 3: Add OutboxStore observation to ChatDetailView**

Open `GitchatIOS/Features/Conversations/ChatDetailView.swift`. Find the cluster of `@StateObject` / `@ObservedObject` declarations near lines 22, 63, 67-68. Right after `@ObservedObject private var blocks = BlockStore.shared` at line 68, add:

```swift
    @ObservedObject private var outbox = OutboxStore.shared
```

The variable doesn't need to be referenced anywhere — its presence as `@ObservedObject` is what triggers SwiftUI to re-render the view body when the store's `@Published pending` changes. The body's existing read of `visibleMessages` (which now transitively reads `OutboxStore.shared.pendingFor(...)`) will pick up the new pending messages on the re-render.

- [ ] **Step 4: Update `ChatDetailView.visibleMessages` to source from `vm.visibleMessages`**

In the same file, find lines 80-82:

```swift
    private var visibleMessages: [Message] {
        vm.messages.filter { !blocks.isBlocked($0.sender) }
    }
```

Change to:

```swift
    private var visibleMessages: [Message] {
        vm.visibleMessages.filter { !blocks.isBlocked($0.sender) }
    }
```

This is the only render-path read of `vm.messages` that needs to switch. The other `vm.messages` reads in this file (lines 164-165, 713-720) are non-render: scroll-trigger and socket-handler logic, which should still operate on server-confirmed messages.

- [ ] **Step 5: Simplify the socket `onMessageSent` handler**

In the same file, find lines 711-724 inside `onAppearTask()`:

```swift
        socket.onMessageSent = { msg in
            guard msg.conversation_id == vm.conversation.id else { return }
            if vm.messages.contains(where: { $0.id == msg.id }) { return }
            ChatMessageView.seenIds.insert(msg.id)
            if let idx = vm.messages.firstIndex(where: {
                $0.id.hasPrefix("local-") && $0.sender == msg.sender && $0.content == msg.content
            }) {
                vm.messages[idx] = msg
            } else {
                vm.messages.append(msg)
                if msg.sender != auth.login {
                    Task { try? await APIClient.shared.markRead(conversationId: vm.conversation.id) }
                }
            }
        }
```

Replace the entire closure body with:

```swift
        socket.onMessageSent = { msg in
            guard msg.conversation_id == vm.conversation.id else { return }
            if vm.messages.contains(where: { $0.id == msg.id }) { return }
            ChatMessageView.seenIds.insert(msg.id)
            vm.messages.append(msg)
            if msg.sender != auth.login {
                Task { try? await APIClient.shared.markRead(conversationId: vm.conversation.id) }
            }
        }
```

The dropped `firstIndex(where: { $0.id.hasPrefix("local-") && ... })` swap branch is now dead code: pending messages no longer live in `vm.messages`, so the lookup can never match.

- [ ] **Step 6: Build**

Run from the repo root:

```bash
xcodebuild \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=9F169B14-27EF-45AE-A30C-40FC38B1E4C5' \
  build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`. If you see "type 'ChatViewModel' has no member 'visibleMessages'", Step 1 was placed incorrectly — confirm it's at file scope on the class, not nested inside `init` or `load`.

- [ ] **Step 7: Manual smoke test — happy path**

Run on the booted simulator:

```bash
./scripts/run-sim.sh "iPhone 17"
```

In the running app:
1. Open any conversation that has at least one prior message.
2. Type a short message.
3. Tap **Send** and immediately tap **Back**.
4. Wait ~2 seconds.
5. Tap the same conversation to re-enter.

Expected:
- The bubble appears optimistically when you tap Send.
- After re-entry, the message is visible (either as the persisted bubble swapping to the server message, or simply as the server message — both are correct outcomes).
- No "missing then reappearing" flicker beyond ~100ms.

If the bubble vanishes for >1 second on re-entry, something in Step 4 or Step 5 was missed — verify `ChatDetailView.visibleMessages` reads `vm.visibleMessages` and that `@ObservedObject private var outbox` is declared.

- [ ] **Step 8: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift \
        GitchatIOS/Features/Conversations/ChatDetailView.swift
git commit -m "$(cat <<'EOF'
fix(ios): route optimistic sends through OutboxStore (#60)

ChatViewModel.send() now enqueues into OutboxStore and runs the network
call in a Task.detached so the send survives ChatDetailView dismissal.
A new ChatViewModel.visibleMessages computed property merges server
messages with pending entries. ChatDetailView observes OutboxStore so
re-renders fire on every store mutation, and the socket.onMessageSent
handler is simplified now that no local- IDs live in vm.messages.

Resolves the happy path of #60: messages no longer appear lost when the
user backs out of a chat right after tapping send. Failed sends still
disappear silently — Retry/Discard UI lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Failed-send Retry / Discard UI

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/Menu/MessageMenuAction.swift` (add `.retry`, `.discard` cases + their title/icon/destructive metadata)
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatView.swift:333-345` (the private `visibleActions(for:)` helper — early-return reduced action set for pending failed local messages)

This task adds the user-facing affordance so failed sends can be re-triggered or thrown away without retyping.

- [ ] **Step 1: Add `.retry` and `.discard` cases to MessageMenuAction**

Open `GitchatIOS/Features/Conversations/ChatDetail/Menu/MessageMenuAction.swift`. The enum currently has 11 cases (`reply`, `copyText`, ..., `report`). Add two more after `.report`:

```swift
enum MessageMenuAction: Hashable {
    case reply
    case copyText
    case copyImage
    case pin
    case unpin
    case forward
    case seenBy
    case edit
    case unsend
    case delete
    case report
    case retry
    case discard
```

In `func title(seenCount:)`, add the two cases after `.report`:

```swift
        case .report: return "Report"
        case .retry: return "Retry"
        case .discard: return "Discard"
```

In `var systemImage`, add:

```swift
        case .report: return "flag"
        case .retry: return "arrow.clockwise"
        case .discard: return "trash"
```

In `var isDestructive`, add `.discard` to the destructive set:

```swift
    var isDestructive: Bool {
        switch self {
        case .delete, .report, .unsend, .discard: return true
        default: return false
        }
    }
```

`visibleActions(for:isMe:isGroup:isPinned:hasText:hasImageAttachment:)` does **not** need to change — the gating happens at the call site in `ChatView.visibleActions(for:)` so the call site can reach `OutboxStore.shared` to read the failure state.

- [ ] **Step 2: Gate menu actions for pending local messages**

Open `GitchatIOS/Features/Conversations/ChatDetail/ChatView.swift`. Find the private helper at lines 333-346 and replace it entirely with:

```swift
    private func visibleActions(for target: MessageMenuTarget) -> [MessageMenuAction] {
        let msg = target.message

        // Pending local messages get a reduced action set — server-side
        // operations (Reply, Pin, Forward, Edit, etc.) would 404 because
        // the message has no server id yet.
        if msg.id.hasPrefix("local-") {
            if let pending = OutboxStore.shared.pending(
                conversationID: vm.conversation.id,
                localID: msg.id
            ) {
                switch pending.state {
                case .sending:
                    return []                // long-press is a no-op while sending
                case .failed:
                    return [.retry, .discard]
                }
            }
            return []                        // unknown local- id (race) → no actions
        }

        let hasText = !msg.content.isEmpty
        let hasImage = (msg.attachments ?? []).contains { ($0.type == "image") || ($0.mime_type?.hasPrefix("image/") == true) }
            || (msg.attachment_url != nil)
        return MessageMenuAction.visibleActions(
            for: msg,
            isMe: target.isMe,
            isGroup: vm.conversation.isGroup,
            isPinned: vm.pinnedIds.contains(msg.id),
            hasText: hasText,
            hasImageAttachment: hasImage
        )
    }
```

- [ ] **Step 3: Wire `.retry` and `.discard` actions through ChatView.Actions**

The menu invokes actions through closures on the `ChatView.Actions` struct (defined at `ChatView.swift:52-76`). Add two new fields:

In `ChatView.swift:52-76`, add to the `Actions` struct after `onMacCatalystSubmit`:

```swift
        var onRetryPending: (Message) -> Void = { _ in }
        var onDiscardPending: (Message) -> Void = { _ in }
```

Find the `dispatch` switch at lines 357-378 of `ChatView.swift`. After the existing `case .report: actions.onReport(msg)` line, add the two new cases (Swift's exhaustive-switch will fail compilation otherwise):

```swift
        case .retry: actions.onRetryPending(msg)
        case .discard: actions.onDiscardPending(msg)
```

The full final dispatch should look like:

```swift
    private func dispatch(_ action: MessageMenuAction, for msg: Message) {
        switch action {
        case .reply:
            actions.onReply(msg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusProxy.focus()
            }
        case .copyText: actions.onCopyText(msg)
        case .copyImage: actions.onCopyImage(msg)
        case .pin, .unpin: actions.onTogglePin(msg)
        case .forward: actions.onForward(msg)
        case .seenBy: actions.onSeenBy(msg)
        case .edit:
            actions.onEdit(msg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusProxy.focus()
            }
        case .unsend: actions.onUnsend(msg)
        case .delete: actions.onDelete(msg)
        case .report: actions.onReport(msg)
        case .retry: actions.onRetryPending(msg)
        case .discard: actions.onDiscardPending(msg)
        }
    }
```

- [ ] **Step 4: Implement the retry/discard handlers in ChatDetailView**

Open `GitchatIOS/Features/Conversations/ChatDetailView.swift`. Find `private var chatViewActions: ChatView.Actions` (starts around line 310). After the existing `a.onMacCatalystSubmit = { ... }` line at ~382, add:

```swift
        a.onRetryPending = { message in
            guard let pending = OutboxStore.shared.pending(
                conversationID: vm.conversation.id,
                localID: message.id
            ) else { return }
            OutboxStore.shared.retry(pending) { p in
                let convId = p.conversationID
                let localID = p.localID
                let body = p.content
                let replyTo = p.replyToID
                Task.detached(priority: .userInitiated) {
                    do {
                        let msg = try await APIClient.shared.sendMessage(
                            conversationId: convId, body: body, replyTo: replyTo
                        )
                        await MainActor.run {
                            ChatMessageView.seenIds.insert(msg.id)
                            OutboxStore.shared.markDelivered(
                                conversationID: convId, localID: localID
                            )
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
        }
        a.onDiscardPending = { message in
            OutboxStore.shared.discard(
                conversationID: vm.conversation.id,
                localID: message.id
            )
        }
```

Note: the retry's send pipeline is structurally identical to the one in `ChatViewModel.send()` from Task 2 Step 2. Duplication is intentional and small (the only callers are `send()` and `retry`); extracting to a helper would just relocate the closure plumbing without simplifying anything.

- [ ] **Step 5: Build**

```bash
xcodebuild \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=9F169B14-27EF-45AE-A30C-40FC38B1E4C5' \
  build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`. If you see "Switch must be exhaustive", you missed adding `.retry` / `.discard` cases to a switch in `ChatView.swift` — Swift's exhaustive-switch is the safety net here.

- [ ] **Step 6: Manual test — failed send + retry + discard**

Run the app on the simulator (`./scripts/run-sim.sh "iPhone 17"`). Then:

**Sub-test A — Retry:**
1. Stop the API server (`Ctrl+C` in its terminal, or `lsof -ti:3000 | xargs kill -9`).
2. In the app, send any message. After ~5 seconds, the bubble should show a failed indicator (Swift error description visible somewhere on the bubble — current rendering may still need a polish pass; for this test, success = bubble persists with `failed` state, retrievable by long-press).
3. Long-press the failed bubble. Menu should show **Retry** and **Discard** only (no Reply / Copy / Pin / Forward).
4. Restart the API: `cd /Users/ethanmiller/Documents/Companies/Lab3/Gitstar/gitchat-webapp/backend && yarn start:dev` (in a new terminal). Wait for "Application is running on: http://localhost:3000".
5. Long-press the failed bubble again → tap **Retry**.
6. Bubble should re-attempt and succeed; pending bubble swaps to the server message.

**Sub-test B — Discard:**
1. Stop the API again.
2. Send another message → wait for failed.
3. Long-press → tap **Discard**.
4. Bubble vanishes immediately.
5. Restart the API. The message should NOT reappear (it was never sent server-side).

If menu shows other actions (Reply / Pin / etc.) on a failed bubble, Step 2's early-return gating wasn't applied correctly.

- [ ] **Step 7: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/Menu/MessageMenuAction.swift \
        GitchatIOS/Features/Conversations/ChatDetail/ChatView.swift \
        GitchatIOS/Features/Conversations/ChatDetailView.swift
git commit -m "$(cat <<'EOF'
feat(ios): retry/discard menu for failed pending sends (#60)

Adds .retry and .discard cases to MessageMenuAction. When a pending
message is in the .failed state, long-press shows only those two
actions — server-side ops (Reply, Pin, Forward, etc.) would 404 because
no server id exists yet. Retry re-runs the send pipeline through
OutboxStore.retry; Discard removes the pending entry without contacting
the server.

Closes the failure-path UX gap left by the previous commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Cross-conversation isolation + final verification

**Files:** none modified — this task is verification-only.

Final manual sweep against all in-scope acceptance criteria from the spec.

- [ ] **Step 1: Confirm all spec acceptance criteria pass**

With the API running and the app on the simulator:

| AC | Test | Pass criterion |
|----|------|----------------|
| AC1 | Send + back + re-enter (Task 2 Step 7 already covers) | Bubble does not vanish on re-entry |
| AC2 | Send + immediately background the app (home button), wait 5s, foreground | Message visible in conversation; check BE logs `Message sent by ...` |
| AC3 | Stop API, send → fail → back to chat list → re-enter conversation | Failed bubble still visible after re-entry |
| AC5 | Retry + Discard (Task 3 Step 6 already covers) | Both work as specified |
| AC6 | Send normally while staying in chat, watch BE log + simulator | No diffable-data-source crash, no duplicate bubble |

- [ ] **Step 2: Cross-conversation isolation**

1. Stop the API.
2. Open conversation A → send a message → it fails. Tap back.
3. Open conversation B → send a message → it fails. Tap back.
4. Re-open conversation A.

Expected: A shows its own failed bubble; B's failed bubble is NOT visible in A. Vice versa for B.

5. Restart the API. Retry both. Each succeeds independently.

If A's pending leaks into B (or vice versa), the bug is in `OutboxStore.pendingFor(conversationID:)` — re-check the keying.

- [ ] **Step 3: Confirm no regression for in-chat sends**

While staying in a conversation (no back-nav):
1. Send 5 messages in quick succession.
2. Confirm each appears, no duplicates, no out-of-order, no missing.
3. Check BE logs to confirm 5 INSERTs landed.

- [ ] **Step 4: Push the branch**

```bash
git push -u origin fix/issue-60-outbox-store
```

- [ ] **Step 5: Open the PR**

```bash
gh pr create --title "fix(ios): outbox store for view-lifetime-independent sends (#60)" --body "$(cat <<'EOF'
## Summary

- Adds `OutboxStore` (new `@MainActor` singleton) holding pending sends keyed by conversationID, surviving `ChatDetailView` dismissal.
- Routes `ChatViewModel.send()` through the outbox via `Task.detached` so the network call is independent of the view's lifecycle.
- New `vm.visibleMessages` computed property merges server messages with pending entries; `ChatDetailView` observes the store so re-renders fire on every mutation.
- Adds `Retry` / `Discard` menu actions for failed pending sends — gated to those two only (server ops would 404 without a server id).

Closes #60 (scope B per design spec).

## Spec & plan

- Design: `docs/superpowers/specs/2026-04-24-outbox-store-design.md`
- Plan: `docs/superpowers/plans/2026-04-24-outbox-store-implementation.md`

## What's NOT in this PR

- Persistent outbox across app kill (issue's "Out of scope" §1)
- Image-upload path `uploadImagesAndSend` (overlaps with #58)
- Subtle "sending" spinner polish (AC4 — design follow-up)
- Extension parity verification (AC7 — separate team)

## Test plan

- [x] AC1 — Quick send + back + re-enter: bubble persists
- [x] AC2 — App background mid-send: message lands BE-side, visible on next open
- [x] AC3 — Failed pending survives view dismiss + re-entry
- [x] AC5 — Long-press failed bubble shows Retry / Discard only; both work
- [x] AC6 — No duplicate-id crash on diffable data source under socket race
- [x] Cross-conversation isolation
- [x] In-chat rapid 5x send: no regression

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. Open it, verify the diff matches the three commits from Tasks 1-3.

- [ ] **Step 6: Done**

The implementation is complete. Update the spec's `Status:` from `Pending user review` to `Implemented` in a follow-up doc commit if desired (optional).
