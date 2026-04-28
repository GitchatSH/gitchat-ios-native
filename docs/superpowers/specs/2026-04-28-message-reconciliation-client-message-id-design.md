# Message Reconciliation: `client_message_id` Round-Trip

**Date:** 2026-04-28
**Status:** Design ready for implementation plan
**Tracks:** GitHub issue [#88](https://github.com/GitchatSH/gitchat-ios-native/issues/88)
**Supersedes:** Bugs #2, #3, #5 from `2026-04-27-message-reconciliation-architecture-debt.md`

## Context

Five bugs share one architectural root cause: the iOS app's message-reconciliation pipeline coordinates an optimistic `local-*` id with a server id through two mutable, drift-prone surfaces (`messages` array and `seenIds` static set). Bug #1 was patched in `e734137`. Bug #4 was already fixed in a prior change (`SocketClient.swift` lines 102-111 wrap `onMessageSent` invocation in `Task { @MainActor in ... }`). Bugs #2, #3, #5 remain.

This spec replaces the dual-id coordination with a single client-generated `client_message_id` (UUID v4) that survives every boundary: optimistic placeholder (FE) → DB row (BE) → WS broadcast (BE→FE) → cache reload (FE). Combined with bundling text+image into a single message and lifting upload work out of the view-model into an extended app-level outbox, this fixes bugs #2, #3, #5 at the root.

## Scope

**In scope:**
- Bug #2: stuck `local-*` optimistic bubbles after back-out + re-enter mid-upload
- Bug #3: receiver-side message order differs for "text + image" sends
- Bug #5: `MessageCache` persists `local-*` entries that `vm.load()` merge cannot clean

**Out of scope:**
- Bug #1: already patched in `e734137`
- Bug #4: already fixed (handler wraps on `MainActor`)
- Background URLSession / cross-launch resume of upload queue (V2)
- ShareExtension idempotency (legacy: continues to send without `client_message_id`)
- `gitchat_extension` opt-in to `client_message_id` (extension's flow has no analogous bugs)

## Architecture overview

Single client-generated UUID (`client_message_id`) is the identity key across three boundaries: optimistic placeholder (FE) → DB row (BE) → WS broadcast (BE→FE). All message lifecycle (text-only, image-only, text+image) flows through one app-level outbox (`OutboxStore`, extended) decoupled from view-model lifecycle.

```
┌─────────────────────── iOS app process ───────────────────────┐
│  ChatDetailView ──► ChatViewModel.send(content:attachments:)   │
│                          │                                      │
│                          │ 1. create optimistic Message         │
│                          │    (id="local-<cmid>", cmid=<uuid>)  │
│                          │ 2. enqueue PendingMessage             │
│                          ▼                                      │
│                  OutboxStore (singleton, @MainActor)             │
│                  ┌──── lifecycle FSM ────┐                       │
│                  enqueued → uploading →                          │
│                  uploaded → sending → delivered | failed         │
│                          │                                       │
│                          ▼ deliveryHandler(convId)               │
│                  ChatViewModel.messages                          │
│                  (replace optimistic by client_message_id)       │
│                                                                  │
│  SocketClient.onMessageSent ◄──── WS message:sent                │
│                  (match by client_message_id; fall back seenIds) │
│                                                                  │
│  MessageCache: filter local-* on save AND on load                │
└──────────────────────────────────────────────────────────────────┘

┌─────────────────────────── Backend ────────────────────────────┐
│  POST /messages/conversations/:id                              │
│    body: { body, attachments?, client_message_id? }            │
│    if client_message_id provided:                              │
│      SELECT id FROM messages WHERE conv=:c AND cmid=:cmid      │
│      → if found: return existing (no insert, no broadcast)     │
│      → if not: INSERT WITH client_message_id, broadcast        │
│    response: Message { ..., client_message_id }                │
│                                                                │
│  WS message:sent payload now includes client_message_id        │
│                                                                │
│  DB: messages + column client_message_id (uuid, nullable)      │
│      partial unique index (conversation_id, client_message_id) │
│         WHERE client_message_id IS NOT NULL                    │
└────────────────────────────────────────────────────────────────┘
```

## Backend changes

### DB migration

```sql
ALTER TABLE messages ADD COLUMN client_message_id uuid NULL;
CREATE UNIQUE INDEX CONCURRENTLY messages_conv_cmid_unique
  ON messages (conversation_id, client_message_id)
  WHERE client_message_id IS NOT NULL;
```

- Nullable column → existing rows + extension/old-iOS sends remain `NULL`
- Partial unique index → many `NULL`s allowed; uniqueness enforced only when value present
- No backfill needed
- `ADD COLUMN ... NULL` (no DEFAULT) on Postgres 11+ takes a brief `AccessExclusiveLock`, no table rewrite
- `CREATE UNIQUE INDEX CONCURRENTLY` on an empty/sparse partial index builds in ~seconds, no write blocking

### MessageEntity

`src/database/postgres/entities/message.entity.ts`:

```typescript
@Column({ name: 'client_message_id', type: 'uuid', nullable: true })
clientMessageId: string | null;
```

(Partial unique index declared in migration SQL, not TypeORM decorator — TypeORM lacks portable partial-index support.)

### Request DTO

`CreateMessageDto` (extract from current inline body):

```typescript
export class CreateMessageDto {
  @IsString() @MaxLength(2000) body: string;
  @IsOptional() @IsArray() attachments?: AttachmentDto[];
  @IsOptional() @IsUUID() client_message_id?: string;  // NEW
  @IsOptional() @IsUUID() reply_to_id?: string;
  // existing optional fields (shared_post_id, shared_event_id) unchanged
}
```

### `MessagesService.sendMessage` changes

Add idempotency pre-check + race-loss recovery:

```typescript
async sendMessage(conversationId, login, body, attachments, replyToId, ..., clientMessageId?) {
  // existing validation: membership, mute, topic routing

  if (clientMessageId) {
    const existing = await this.messageRepo.findOne({
      where: { conversationId, clientMessageId },
    });
    if (existing) return this.toResponseShape(existing);  // no insert, no broadcast
  }

  let inserted;
  try {
    inserted = await this.messageRepo.save({
      conversationId, senderLogin: login, body,
      clientMessageId: clientMessageId ?? null,
      // ... reply_to, type, etc.
    });
  } catch (err) {
    if (isUniqueViolation(err, 'messages_conv_cmid_unique') && clientMessageId) {
      const existing = await this.messageRepo.findOneOrFail({
        where: { conversationId, clientMessageId },
      });
      return this.toResponseShape(existing);
    }
    throw err;
  }

  // existing: attachment inserts, conversation metadata, topic unread

  const wsEvents = [{
    event_name: WS_EVENT_NAMES.MESSAGE_SENT,
    room: messageSentRoom,
    timestamp: Date.now(),
    data: { ...sentMessage, client_message_id: inserted.clientMessageId, topicId: topicIdForPayload },
  }];
  // existing broadcast logic unchanged
}
```

### Response shape

`Message` interface (controller-level serialization) gains:

```typescript
client_message_id: string | null;
```

Applied to:
- HTTP response of `POST /messages/conversations/:id`
- WS broadcast `message:sent` payload (and `topic:message` alias)
- HTTP response of message-history endpoint(s) — needed for FE merge by `client_message_id` on `vm.load()`

### Topics interaction

`topicsEnabled=true` auto-routes to General child. Logic unchanged:
- `client_message_id` stored on the child topic message row (not on parent thread)
- Dedup check matches `(child_conversation_id, client_message_id)`
- WS `topic:message` alias also includes `client_message_id`

### No new endpoints

A `GET /messages/by-client-id/:cmid` lookup endpoint is **not** needed:
- OutboxStore queue persists in-memory while app runs → on VM re-init, retry pending sends
- BE dedup → idempotent retry returns existing message
- History endpoint already supports merge by `client_message_id` on `vm.load()`

### Validation & rate limit

- `@IsUUID()` rejects malformed `client_message_id` with 400
- Existing per-user-per-conversation rate limit applied before dedup check → spam still rejected
- UUID v4 cross-sender collision is statistically negligible; treated as acceptable risk

## OutboxStore extension

### `PendingMessage` model

```swift
struct PendingMessage {
    let clientMessageID: String      // UUID v4, identity key
    let conversationID: String
    var content: String              // body text (may be "")
    var replyToID: String?
    var attachments: [PendingAttachment]  // [] for text-only
    var attempts: Int
    var createdAt: Date
    var state: State
}

struct PendingAttachment {
    let clientAttachmentID: String   // UUID per attachment
    let sourceData: Data             // JPEG/PNG bytes
    let mimeType: String
    let width: Int?
    let height: Int?
    let blurhash: String?
    var uploaded: UploadedRef?       // nil until upload step succeeds
}

struct UploadedRef { let url: String; let storagePath: String; let sizeBytes: Int }

enum State {
    case enqueued
    case uploading(progress: Double)        // 0.0..1.0
    case uploaded                            // all attachments have URLs
    case sending                             // POST send in flight
    case delivered                           // server returned, handler invoked
    case failed(reason: String, retriable: Bool)
}
```

The legacy `localID` field is removed; the optimistic Message id is derived as `"local-\(clientMessageID)"` so existing UI prefix-checks (spinner detection) keep working.

### Lifecycle FSM

```
enqueued
   │ attachments.isEmpty?
   │   ├── yes ──► sending
   │   └── no  ──► uploading(0.0)
   ▼
uploading(p)  ── upload all attachments sequentially (V1)
   │ all uploaded != nil
   ▼
uploaded
   │ POST /messages/conversations/:id { body, attachments[], client_message_id }
   ▼
sending
   ├── 200 ──► delivered (deliveryHandler invoked) ──► remove from queue
   ├── 4xx ──► failed(retriable: false)            ──► UI shows error
   └── network/5xx ──► failed(retriable: true) + backoff ──► retry
```

All transitions on `MainActor` (`OutboxStore` is a `@MainActor` singleton).

### `executeSend` (extended)

```swift
@MainActor
private func executeSend(_ pending: PendingMessage) async {
    var p = pending

    if !p.attachments.isEmpty && p.attachments.contains(where: { $0.uploaded == nil }) {
        p.state = .uploading(progress: 0.0); update(p)
        for i in p.attachments.indices where p.attachments[i].uploaded == nil {
            do {
                let ref = try await APIClient.shared.uploadAttachment(
                    conversationID: p.conversationID,
                    data: p.attachments[i].sourceData,
                    mimeType: p.attachments[i].mimeType
                )
                p.attachments[i].uploaded = UploadedRef(url: ref.url, storagePath: ref.storagePath, sizeBytes: ref.sizeBytes)
                update(p)
            } catch {
                p.state = .failed(reason: "Upload failed: \(error)", retriable: true)
                update(p); scheduleRetry(p); return
            }
        }
        p.state = .uploaded; update(p)
    }

    p.state = .sending; update(p)
    do {
        let serverMsg = try await APIClient.shared.sendMessage(
            conversationID: p.conversationID,
            body: p.content,
            attachments: p.attachments.compactMap(\.uploaded),
            replyToID: p.replyToID,
            clientMessageID: p.clientMessageID
        )
        p.state = .delivered; update(p)
        deliveryHandlers[p.conversationID]?(serverMsg)
        markDelivered(p)
    } catch {
        p.attempts += 1
        let retriable = isRetriableError(error) && p.attempts < 5
        p.state = .failed(reason: "\(error)", retriable: retriable)
        update(p)
        if retriable { scheduleRetry(p) }
    }
}
```

### Delivery handler contract

`ChatDetailView.swift` registers per-conversation handler that matches by `client_message_id`:

```swift
OutboxStore.shared.registerDeliveryHandler(conversationID: vm.conversation.id) { [weak vm] msg in
    guard let vm else { return }
    if let cmid = msg.client_message_id,
       let idx = vm.messages.firstIndex(where: { $0.client_message_id == cmid }) {
        vm.messages[idx] = msg
    } else if !vm.messages.contains(where: { $0.id == msg.id }) {
        vm.messages.append(msg)
    }
}
```

Outbound now matches by `client_message_id`. Inbound dedup via `seenIds` is preserved (see §"`seenIds` retained" below).

### Upload concurrency

V1: sequential per pending message. Avoids upload-endpoint quota concerns and simplifies progress reporting. V2 may parallelize with a semaphore.

### Retry & backoff

- Retriable: timeout, 5xx, network unreachable
- Non-retriable: 4xx (validation, mute, ban), unsupported MIME, file too large
- Backoff: 2s → 4s → 8s → 16s → 32s, capped at 5 attempts; then `failed(retriable: false)` with manual retry button

### Cancel & discard

V1 cancel semantics:
- User taps "X" on a bubble in `enqueued` or `failed` state → `OutboxStore.cancel(clientMessageID)` removes from queue and from `vm.messages`. Safe — no network operation in flight.
- User taps "X" while bubble is in `uploading` or `sending` state → cancel button is **disabled** in V1. Interrupting an in-flight `URLSession` task is V2 work.
- User taps "Retry" on `failed(retriable: true)` bubble → re-enqueue with `attempts = 0`.

### `ChatViewModel` role change

**Before:** VM directly calls `uploadAttachment` + `sendMessage` via `uploadAndSend` / `sendEncodedAttachments` / `uploadImagesAndSend`.

**After:** VM only:
1. Builds optimistic `Message(id: "local-\(cmid)", client_message_id: cmid, ...)`, appends to `messages`
2. Builds `PendingMessage`, calls `OutboxStore.enqueue(...)`
3. Registers delivery handler

Methods removed/inlined: `uploadAndSend`, `sendEncodedAttachments`, `uploadImagesAndSend`. Single entry point: `vm.send(content:attachments:replyTo:)`.

### Persistence (V1)

In-memory only inside the app process. iOS may terminate the app ~30s after backgrounding — pending uploads/sends are lost. Documented limitation.

V2 (out of scope here): persist queue to disk + background URLSession so uploads survive app kill.

### Out of scope (V1)

- Background URLSession (uploads while app suspended)
- Cross-launch queue resume
- Cancel of in-flight upload (interrupt URL session task)

## iOS frontend changes

### `Message` model

`models.swift` adds optional field:

```swift
struct Message: Codable, Identifiable {
    let id: String
    let client_message_id: String?    // nil for legacy / extension-sent
    // existing fields
}
```

Codable synthesis tolerates `null` / missing field — no breaking change for legacy payloads.

### `ChatViewModel.send` (single entry point)

```swift
@MainActor
func send(content: String, attachments: [PendingAttachment] = [], replyTo: Message? = nil) {
    guard !content.isEmpty || !attachments.isEmpty else { return }

    let cmid = UUID().uuidString
    let optimistic = Message(
        id: "local-\(cmid)",
        client_message_id: cmid,
        conversation_id: conversation.id,
        sender: auth.login,
        content: content,
        attachments: attachments.map { $0.toOptimisticAttachment() },
        created_at: ISO8601DateFormatter().string(from: Date()),
        // other defaults
    )
    messages.append(optimistic)
    persistCache()  // filter strips local-* before disk write

    OutboxStore.shared.enqueue(PendingMessage(
        clientMessageID: cmid,
        conversationID: conversation.id,
        content: content,
        replyToID: replyTo?.id,
        attachments: attachments,
        attempts: 0,
        createdAt: Date(),
        state: .enqueued
    ))
}
```

### `ChatViewModel.load()` & `loadMoreIfNeeded()` merge logic

```swift
private func mergeFromServer(_ fetched: [Message]) {
    var existing = self.messages
    for srv in fetched {
        if let cmid = srv.client_message_id,
           let idx = existing.firstIndex(where: { $0.client_message_id == cmid }) {
            existing[idx] = srv
            continue
        }
        if let idx = existing.firstIndex(where: { $0.id == srv.id }) {
            existing[idx] = srv
            continue
        }
        existing.append(srv)
    }
    existing.removeAll { msg in
        guard msg.id.hasPrefix("local-") else { return false }
        guard let cmid = msg.client_message_id else { return true }  // legacy junk
        return fetched.contains { $0.client_message_id == cmid && !$0.id.hasPrefix("local-") }
    }
    self.messages = existing
}
```

### `MessageCache` filter

Save (`ChatViewModel.persistCache`):

```swift
MessageCache.shared.store(conversation.id, entry: MessageCache.Entry(
    messages: self.messages.filter { !$0.id.hasPrefix("local-") },
    nextCursor: self.nextCursor,
    // ...
))
```

Load (`ChatViewModel.init` from cache):

```swift
if let cached = MessageCache.shared.get(conversation.id) {
    self.messages = cached.messages.filter { !$0.id.hasPrefix("local-") }
    // ...
}
```

Defense in depth: prevention on save, cleanup on load.

### `SocketClient.onMessageSent` matching

`ChatDetailView.swift` lines 722-733:

```swift
socket.onMessageSent = { msg in
    guard msg.conversation_id == vm.conversation.id else { return }
    if let cmid = msg.client_message_id,
       let idx = vm.messages.firstIndex(where: { $0.client_message_id == cmid }) {
        vm.messages[idx] = msg
        ChatMessageView.seenIds.insert(msg.id)
        return
    }
    guard ChatMessageView.seenIds.insert(msg.id).inserted else { return }
    vm.messages.append(msg)
    if msg.sender != auth.login {
        Task { try? await APIClient.shared.markRead(...) }
    }
}
```

### `APIClient.sendMessage` signature

```swift
func sendMessage(
    conversationID: String,
    body: String,
    attachments: [UploadedRef] = [],
    replyToID: String? = nil,
    clientMessageID: String? = nil    // NEW
) async throws -> Message
```

### `seenIds` retained

`ChatMessageView.seenIds` is **not** removed:
- Inbound from other senders has no optimistic match → still needs `seenIds` for dedup across WS replay/disconnect
- Outbound now dedups via `client_message_id` (id-shape stable, no drift)
- Both contracts coexist; each handles one direction

`seenIds` writes occur only on `MainActor` (callers either run on main directly or wrap in `Task { @MainActor in ... }`).

### ShareExtension

V1: ShareExtension continues to send without `client_message_id` (BE accepts as `NULL`, no dedup). ShareExtension has no optimistic UI, so bugs #2 / #5 don't apply. Documented limitation: rapid duplicate share could create duplicate messages — acceptable, future work.

## Migration & rollout

### Deploy order

**BE deploys before iOS App Store update.**

| Scenario | Result |
|---|---|
| Old iOS + Old BE | Behavior unchanged |
| Old iOS + New BE | iOS omits `client_message_id` → BE inserts `NULL`, no dedup → behavior unchanged |
| New iOS + Old BE (deploy gap) | New iOS sends `client_message_id` → Old BE must ignore unknown fields, not reject 400 |

**Pre-build verification:** confirm NestJS `ValidationPipe` is configured with `forbidNonWhitelisted: false` (or unset). If `true`, new iOS sends will be rejected during the deploy gap.

### DB migration safety

- `ALTER TABLE messages ADD COLUMN client_message_id uuid NULL` (no DEFAULT) — fast on Postgres 11+, no rewrite
- `CREATE UNIQUE INDEX CONCURRENTLY` — non-blocking; on partial-empty data, builds in seconds
- Migration runs as part of normal deploy; rollback path: drop index, drop column (no data loss)

### iOS rollout

- Build new iOS with extended `OutboxStore` + unified `send` → submit App Store
- During Apple review (~1-3 days), BE is already serving `client_message_id`. Old-app users keep working.
- Once user updates, local cache may contain legacy `local-*`; load filter cleans on first `init`. Zero migration friction.

### Extension compatibility

Verified zero impact (no schema validator, axios + Socket.IO loose decoders). Extension code unchanged.

### Verification checklist (BE)

- [ ] `ValidationPipe.forbidNonWhitelisted` is false / unset
- [ ] Migration runs cleanly on staging; lock duration measured
- [ ] Idempotency test: 2 concurrent POSTs with same `client_message_id` → 1 row, both callers receive same Message
- [ ] Validation rejects malformed UUID with 400
- [ ] Topic routing: `topicsEnabled=true` conv → cmid stored on child message, broadcast carries cmid
- [ ] Reply: send with `reply_to_id` + `client_message_id` → both fields persisted
- [ ] Extension regression: send without cmid still works

### Verification checklist (iOS)

- [ ] Stress paste: 5 images in 2s → 0 crashes, 0 duplicates
- [ ] Back-out + re-enter mid-upload: bubble reconciles after upload completes
- [ ] Force-quit mid-upload: cache contains no orphan `local-*` after relaunch
- [ ] Image + caption send: 1 bubble both sides, identical order
- [ ] Network drop mid-send: retry with backoff, BE dedup prevents duplicates
- [ ] Cache leak cleanup: legacy `local-*` from old build removed on first `vm.load()` after upgrade
- [ ] Receive from extension (no cmid): renders correctly, no crash on `nil` field

### Feature flag

Not used. Rollback path is the same code-revert + migration drop; complexity not justified.

## Testing strategy

### BE unit tests (`backend/test/unit/messages.service.spec.ts`)

```typescript
describe('sendMessage with client_message_id', () => {
  it('inserts row with client_message_id when provided');
  it('returns existing message when same (conversationId, client_message_id) exists, does NOT broadcast WS again');
  it('inserts NULL when client_message_id omitted (legacy clients)');
  it('handles unique-violation race: 2 concurrent calls with same cmid → same Message returned, exactly 1 row exists');
  it('rejects malformed UUID with 400 (validation)');
  it('persists client_message_id correctly under topic routing');
  it('includes client_message_id in WS broadcast payload');
});
```

Race test pattern:

```typescript
const cmid = uuidv4();
const [r1, r2] = await Promise.all([
  service.sendMessage(convId, login, 'hi', [], null, cmid),
  service.sendMessage(convId, login, 'hi', [], null, cmid),
]);
expect(r1.id).toBe(r2.id);
const rows = await repo.find({ where: { conversationId: convId, clientMessageId: cmid } });
expect(rows).toHaveLength(1);
```

### BE integration tests (`backend/test/e2e/messages.e2e-spec.ts`)

```typescript
describe('POST /messages/conversations/:id idempotency', () => {
  it('same cmid twice → 1 message, 1 broadcast');
  it('different cmid → 2 messages, 2 broadcasts');
  it('cmid omitted → message created normally (extension compat)');
  it('cmid + attachments + reply_to_id → all preserved on row');
});
```

### FE unit tests — `OutboxStore` lifecycle

```swift
func test_textOnly_skipsUploadingState() async
func test_withAttachments_transitions_enqueued_uploading_uploaded_sending_delivered() async
func test_uploadFailure_transitionsToFailed_retriable() async
func test_serverReturns4xx_transitionsToFailed_nonRetriable() async
func test_concurrentEnqueue_serialFIFO_per_conversation() async
func test_deliveryHandler_invokedOnceWithServerMessage() async
func test_clientMessageID_propagatedToAPIClient() async
func test_unregisteredHandler_doesNotCrash_messageStillDelivered() async
```

### FE unit tests — `ChatViewModel.mergeFromServer`

```swift
func test_serverMessage_replacesOptimistic_byClientMessageID()
func test_serverMessage_appendedWhenNoMatch()
func test_orphanLocalCmid_cleanedWhenServerArrivesUnderDifferentBranch()
func test_legacyLocalWithoutCmid_isCleanedOnNextLoad()
```

### FE unit tests — `MessageCache` filter

```swift
func test_persistCache_excludes_localPrefix_messages()
func test_load_filters_legacy_localPrefix_messages_alreadyOnDisk()
```

### FE unit tests — `SocketClient.onMessageSent` matching

```swift
func test_inboundMessage_withMatchingCmid_replacesOptimistic()
func test_inboundMessage_noCmid_appendedViaSeenIdsDedup()
func test_inboundMessage_alreadySeen_isIgnored()
```

### Manual test plan (mapped to bugs)

| Bug | Scenario | Expected |
|---|---|---|
| #1 (regression) | Stress paste 5 images in 2s | 0 crash, 0 duplicate, all bubbles render |
| #2 | Paste image → back out mid-upload → re-enter | Bubble reconciles after upload completes; if app killed, cache contains no leak |
| #2 (extreme) | Paste image → kill app → reopen | Optimistic gone, no ghost bubble. User must manually re-send if desired |
| #3 | Type "look at this" + paste 2 images → send | 1 bubble (caption + 2 images), same order on both sides |
| #5 | Install old app, leak `local-*`, install new app | Orphan removed after first `vm.load()` |
| Bonus | Network drop mid-send | Retry with backoff, BE dedup, final bubble has server id |
| Bonus | Double-tap send | BE dedup, single bubble |

### Compatibility regression manual

| Scenario | Expected |
|---|---|
| Old iOS + New BE | Send works, BE accepts cmid=NULL |
| New iOS + Old BE | Send works only if BE doesn't reject unknown fields (verify pre-build) |
| Extension → New iOS | Inbound renders, `client_message_id == nil` no crash |
| New iOS → Extension | Extension ignores extra field |
| ShareExtension (no cmid) → main app | Renders correctly |

### Performance

- Measure BE dedup `SELECT WHERE conv=:c AND cmid=:cmid` p50/p95 latency. Expected <2ms (covered by partial unique index).
- OutboxStore queue depth stress test: 50 pending sends → memory footprint, FIFO chain integrity.

### Telemetry (nice-to-have, not blocking)

- BE log on dedup hit: `info: cmid_dedup_hit conv=... cmid=...`
- FE log on optimistic replace: `debug: cmid_match replaced=local-... → srv-...`

## Open questions

None at design-acceptance time. All decisions chosen during brainstorming:
- DB persistence: **persisted** (column + partial unique index)
- Ordering for "text + image": **bundle into one message**
- Upload lifecycle: **singleton manager (extended OutboxStore), survives VM**
- Cache migration: **filter on save AND load**
- Refactor scope: **extend `OutboxStore` (single outbox)**

## References

- Spec: `docs/superpowers/specs/2026-04-27-message-reconciliation-architecture-debt.md`
- Spec: `docs/superpowers/specs/2026-04-26-paste-image-from-clipboard-design.md`
- Spec: `docs/superpowers/specs/2026-04-24-outbox-store-design.md`
- Issue: https://github.com/GitchatSH/gitchat-ios-native/issues/88
- Bug #1 patch: commit `e734137`
- Reverted bundling fix (now safe to revisit): `a8f62c2` → `3782128`
