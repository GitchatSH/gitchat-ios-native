# `client_message_id` Round-Trip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace optimistic `local-*` / server-id dual-id coordination with a single client-generated UUID (`client_message_id`) that survives optimistic placeholder, BE row, WS broadcast, and cache reload — fixing bugs #2, #3, #5 from `docs/superpowers/specs/2026-04-27-message-reconciliation-architecture-debt.md`.

**Architecture:** BE adds nullable `client_message_id` column with partial unique index for idempotency. iOS unifies all sends through an extended `OutboxStore` (single outbox, in-memory, decoupled from VM lifecycle) that handles upload + send as a single FSM. ChatViewModel matches optimistic ↔ server messages by `client_message_id`. MessageCache filters `local-*` on save AND load.

**Tech Stack:** NestJS + TypeORM + Postgres (BE), Swift 5.9 + SwiftUI + iOS 16+ (FE), Socket.IO (transport).

**Spec:** `docs/superpowers/specs/2026-04-28-message-reconciliation-client-message-id-design.md`
**Issue:** https://github.com/GitchatSH/gitchat-ios-native/issues/88
**Branch:** `feat/issue-88-cmid-roundtrip`

**Repos:**
- iOS: `/Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat-ios-native` (this plan lives here)
- BE: `/Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat-webapp/backend`
- Extension (no changes): `/Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat_extension`

---

## Phase 0 — iOS unit test target setup

Existing iOS repo has only `GitchatIOSUITests` (XCUIApplication). Bug-pipeline FSM testing needs a unit test target. This phase adds it once for use across this and future plans.

### Task 0.1: Add `GitchatIOSTests` unit-test target to `project.yml`

**Files:**
- Modify: `/Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat-ios-native/project.yml:14-18` (schemes.GitchatIOS.test.targets)
- Modify: `/Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat-ios-native/project.yml:244` (insert new target above `GitchatIOSUITests`)
- Create: `GitchatIOSTests/Info.plist`
- Create: `GitchatIOSTests/SmokeUnitTest.swift`

- [ ] **Step 1: Modify the test scheme list**

In `project.yml` lines 14-18, change:
```yaml
    test:
      config: Debug
      targets:
        - GitchatIOSUITests
```
to:
```yaml
    test:
      config: Debug
      targets:
        - GitchatIOSTests
        - GitchatIOSUITests
```

- [ ] **Step 2: Append the new target definition**

After line 243 (right before `GitchatIOSUITests:`), insert:
```yaml
  GitchatIOSTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "16.0"
    sources:
      - path: GitchatIOSTests
    dependencies:
      - target: GitchatIOS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: chat.git.unittests
        BUNDLE_LOADER: $(TEST_HOST)
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/Gitchat.app/Gitchat
        SUPPORTS_MACCATALYST: YES
        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO
    info:
      path: GitchatIOSTests/Info.plist
      properties:
        CFBundleName: $(PRODUCT_NAME)
        CFBundlePackageType: BNDL
```

- [ ] **Step 3: Create `GitchatIOSTests/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>$(DEVELOPMENT_LANGUAGE)</string>
  <key>CFBundleExecutable</key>
  <string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
```

- [ ] **Step 4: Create smoke test `GitchatIOSTests/SmokeUnitTest.swift`**

```swift
import XCTest
@testable import Gitchat

final class SmokeUnitTest: XCTestCase {
    func test_unitTestTarget_isWired() {
        XCTAssertTrue(true, "Smoke: unit test target compiles and runs")
    }
}
```

- [ ] **Step 5: Regenerate Xcode project**

Run: `cd /Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat-ios-native && xcodegen generate`
Expected: `Generated project successfully` and `GitchatIOS.xcodeproj` updated.

- [ ] **Step 6: Build and run the smoke test**

Run:
```bash
cd /Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat-ios-native
xcodebuild test \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:GitchatIOSTests/SmokeUnitTest/test_unitTestTarget_isWired
```
Expected: `Test Suite 'SmokeUnitTest' passed` in output.

- [ ] **Step 7: Commit**

```bash
git add project.yml GitchatIOS.xcodeproj GitchatIOSTests/
git commit -m "chore(ios): add GitchatIOSTests unit-test target

Adds a dedicated unit test target for non-UI tests (FSM,
view-models, parsing). Existing GitchatIOSUITests stays for
XCUIApplication-level coverage.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 1 — Backend: schema, DTO, dedup

All BE work happens in `/Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat-webapp/backend`. The plan path here references that absolute path; commits go to the BE repo's git history (separate from iOS repo).

### Task 1.1: Verify BE branch & deps

**Files:** none

- [ ] **Step 1: Create / switch to feature branch in BE repo**

```bash
cd /Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat-webapp/backend
git checkout -b feat/issue-88-cmid-roundtrip
```

- [ ] **Step 2: Verify install state**

```bash
pnpm install --frozen-lockfile
```
Expected: install succeeds without errors.

- [ ] **Step 3: Verify existing tests pass before changes**

```bash
pnpm test --runInBand
```
Expected: green baseline.

### Task 1.2: DB migration — add `client_message_id` column

**Files:**
- Create: `src/database/postgres/migrations/<timestamp>-add-client-message-id-to-messages.ts`

(Replace `<timestamp>` with `Date.now()` value, e.g., `1714287600000`.)

- [ ] **Step 1: Generate migration filename**

Run from `gitchat-webapp/backend`:
```bash
TIMESTAMP=$(node -e "process.stdout.write(Date.now().toString())")
echo "src/database/postgres/migrations/${TIMESTAMP}-add-client-message-id-to-messages.ts"
```
Use the printed path as the migration file name.

- [ ] **Step 2: Create the migration file**

```typescript
import { MigrationInterface, QueryRunner } from 'typeorm';

export class AddClientMessageIdToMessages1714287600000 implements MigrationInterface {
  name = 'AddClientMessageIdToMessages1714287600000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE messages ADD COLUMN client_message_id uuid NULL;`);
    // CREATE INDEX CONCURRENTLY cannot run inside a transaction. The migration
    // tooling here wraps queries in a transaction by default. Use a regular
    // CREATE UNIQUE INDEX since the partial index over a NULL-only column
    // builds in milliseconds and acquires a brief share-lock.
    await queryRunner.query(`
      CREATE UNIQUE INDEX messages_conv_cmid_unique
        ON messages (conversation_id, client_message_id)
        WHERE client_message_id IS NOT NULL;
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP INDEX IF EXISTS messages_conv_cmid_unique;`);
    await queryRunner.query(`ALTER TABLE messages DROP COLUMN IF EXISTS client_message_id;`);
  }
}
```

- [ ] **Step 3: Run migration on local dev DB**

```bash
pnpm migration:run
```
Expected: log line `Migration AddClientMessageIdToMessages... has been executed successfully.`

- [ ] **Step 4: Verify column exists**

```bash
psql "$DEV_DB_URL" -c "\d messages" | grep client_message_id
```
Expected: row showing `client_message_id | uuid | nullable`.

- [ ] **Step 5: Verify partial unique index exists**

```bash
psql "$DEV_DB_URL" -c "\d messages_conv_cmid_unique"
```
Expected: shows partial index definition with `WHERE (client_message_id IS NOT NULL)`.

- [ ] **Step 6: Test migration rollback**

```bash
pnpm migration:revert
psql "$DEV_DB_URL" -c "\d messages" | grep client_message_id || echo "column dropped"
pnpm migration:run    # re-apply for subsequent tasks
```
Expected: `column dropped`, then re-apply succeeds.

- [ ] **Step 7: Commit**

```bash
git add src/database/postgres/migrations/
git commit -m "feat(db): add client_message_id column + partial unique index to messages

Nullable uuid column for client-generated message identity, plus
a partial unique index on (conversation_id, client_message_id)
WHERE NOT NULL — enables idempotency for clients sending cmid
without conflicting with NULL rows from legacy/extension clients.

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 1.3: Update `MessageEntity`

**Files:**
- Modify: `src/database/postgres/entities/message.entity.ts`

- [ ] **Step 1: Add field to MessageEntity**

After the existing column declarations (e.g., after `replyToId`), add:
```typescript
@Column({ name: 'client_message_id', type: 'uuid', nullable: true })
clientMessageId: string | null;
```

- [ ] **Step 2: Build to verify TypeScript compiles**

```bash
pnpm build
```
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/database/postgres/entities/message.entity.ts
git commit -m "feat(messages): add clientMessageId to MessageEntity

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 1.4: Create `CreateMessageDto` (extracts inline body type)

**Files:**
- Create: `src/modules/messages/dto/create-message.dto.ts`
- Modify: `src/modules/messages/controllers/messages.controller.ts:247` (the send-message endpoint)

- [ ] **Step 1: Create the DTO file**

```typescript
import { IsString, IsOptional, IsArray, IsUUID, MaxLength, ValidateNested } from 'class-validator';
import { Type } from 'class-transformer';

export class AttachmentInputDto {
  @IsString() type: string;
  @IsString() url: string;
  @IsString() storage_path: string;
  @IsOptional() @IsString() filename?: string;
  @IsOptional() @IsString() mime_type?: string;
  @IsOptional() size_bytes?: number;
  @IsOptional() width?: number;
  @IsOptional() height?: number;
  @IsOptional() @IsString() blurhash?: string;
}

export class CreateMessageDto {
  @IsString() @MaxLength(2000)
  body: string;

  @IsOptional()
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => AttachmentInputDto)
  attachments?: AttachmentInputDto[];

  @IsOptional() @IsUUID()
  client_message_id?: string;

  @IsOptional() @IsUUID()
  reply_to_id?: string;

  @IsOptional() @IsUUID()
  shared_post_id?: string;

  @IsOptional() @IsUUID()
  shared_event_id?: string;
}
```

- [ ] **Step 2: Update controller signature**

In `messages.controller.ts` around line 247, replace the inline type:
```typescript
@Body() body: { body: string; attachments?: Array<Record<string, any>>; reply_to_id?: string; shared_post_id?: string; shared_event_id?: string },
```
with:
```typescript
@Body() body: CreateMessageDto,
```

Add the import at the top of the file:
```typescript
import { CreateMessageDto } from '../dto/create-message.dto';
```

- [ ] **Step 3: Pass `client_message_id` to service call**

Inside the controller method, locate the call to `messagesService.sendMessage(...)`. Append `body.client_message_id` as the new last argument. The service signature change is in Task 1.5.

- [ ] **Step 4: Build to surface any type errors**

```bash
pnpm build
```
Expected: TypeScript error about service signature (will be fixed in Task 1.5). Note the exact error to confirm wiring.

- [ ] **Step 5: Stash this change**

Don't commit yet; Task 1.5 completes the wiring. Hold the diff in the working tree.

### Task 1.5: Service dedup pre-check (TDD — RED)

**Files:**
- Modify: `src/modules/messages/services/messages.service.ts` (function `sendMessage` at line ~1108)
- Modify: `test/unit/messages.service.spec.ts` (or create if missing)

- [ ] **Step 1: Locate test file**

```bash
find test/unit -name "messages.service.spec.ts" 2>/dev/null || \
  find test -name "messages*.spec.ts" 2>/dev/null
```
If no spec exists, create one at `test/unit/messages.service.spec.ts` with the appropriate Jest setup matching other unit tests in the project. Use an existing service spec as a scaffold (look in `test/unit/` for any `.service.spec.ts`).

- [ ] **Step 2: Write failing test for happy-path idempotency**

Inside the spec's `describe('MessagesService', () => { ... })`:
```typescript
describe('sendMessage with client_message_id', () => {
  it('returns existing message when same (conversationId, client_message_id) seen twice, without re-broadcasting', async () => {
    const cmid = '11111111-1111-4111-8111-111111111111';
    const conv = await fixtures.createConversation({ participants: ['alice', 'bob'] });

    const first = await service.sendMessage(conv.id, 'alice', 'hi', [], null, undefined, undefined, cmid);
    const second = await service.sendMessage(conv.id, 'alice', 'hi', [], null, undefined, undefined, cmid);

    expect(first.id).toBe(second.id);
    const rows = await messageRepo.find({ where: { conversationId: conv.id, clientMessageId: cmid } });
    expect(rows).toHaveLength(1);
    expect(wsEmitterSpy).toHaveBeenCalledTimes(1);  // broadcast only once
  });
});
```

(Adjust positional args to match current `sendMessage` signature; the service currently takes `(conversationId, login, body, attachments, replyToId, sharedPostId, sharedEventId)` — `clientMessageId` is added as the 8th arg.)

- [ ] **Step 3: Run the test and confirm it fails**

```bash
pnpm jest --config test/jest-unit.json messages.service.spec.ts -t 'returns existing message when same'
```
Expected: FAIL — either signature mismatch (`clientMessageId` doesn't exist as parameter) or 2 rows inserted instead of 1.

### Task 1.6: Service dedup pre-check (GREEN)

**Files:**
- Modify: `src/modules/messages/services/messages.service.ts:1108` (function `sendMessage` signature + body)

- [ ] **Step 1: Add `clientMessageId` parameter**

Append to the signature:
```typescript
async sendMessage(
  conversationId: string,
  login: string,
  body: string,
  attachments: any[],
  replyToId: string | null,
  sharedPostId?: string,
  sharedEventId?: string,
  clientMessageId?: string,        // NEW
): Promise<Message> {
```

- [ ] **Step 2: Add idempotency pre-check**

After existing validation (membership, mute), before topic routing, insert:
```typescript
if (clientMessageId) {
  const existing = await this.messageRepo.findOne({
    where: { conversationId, clientMessageId },
  });
  if (existing) {
    return this.toResponseShape(existing);  // no insert, no broadcast
  }
}
```

(If `toResponseShape` doesn't exist, locate the function that converts `MessageEntity` to the controller-returned shape — likely a private helper near the bottom of the service or inline mapping.)

- [ ] **Step 3: Persist `clientMessageId` on insert**

Locate the `INSERT` / `messageRepo.save(...)` call in the service and add `clientMessageId: clientMessageId ?? null` to the field list.

- [ ] **Step 4: Run the failing test — should now pass**

```bash
pnpm jest --config test/jest-unit.json messages.service.spec.ts -t 'returns existing message when same'
```
Expected: PASS.

- [ ] **Step 5: Run all unit tests to check no regressions**

```bash
pnpm jest --config test/jest-unit.json
```
Expected: all pre-existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add test/unit/messages.service.spec.ts \
        src/modules/messages/dto/create-message.dto.ts \
        src/modules/messages/controllers/messages.controller.ts \
        src/modules/messages/services/messages.service.ts
git commit -m "feat(messages): idempotent sendMessage by client_message_id

Adds CreateMessageDto with optional client_message_id, threads it
through controller and service, and skips the insert + broadcast
when a row with the same (conversation_id, client_message_id)
already exists.

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 1.7: Race recovery (TDD — RED)

**Files:**
- Modify: `test/unit/messages.service.spec.ts`

- [ ] **Step 1: Add concurrent-call test**

Inside the same `describe('sendMessage with client_message_id', ...)`:
```typescript
it('handles concurrent inserts with same cmid: 1 row, both callers receive same Message', async () => {
  const cmid = '22222222-2222-4222-8222-222222222222';
  const conv = await fixtures.createConversation({ participants: ['alice', 'bob'] });

  const [r1, r2] = await Promise.all([
    service.sendMessage(conv.id, 'alice', 'race', [], null, undefined, undefined, cmid),
    service.sendMessage(conv.id, 'alice', 'race', [], null, undefined, undefined, cmid),
  ]);

  expect(r1.id).toBe(r2.id);
  const rows = await messageRepo.find({ where: { conversationId: conv.id, clientMessageId: cmid } });
  expect(rows).toHaveLength(1);
});
```

- [ ] **Step 2: Run the test — confirm it fails**

```bash
pnpm jest --config test/jest-unit.json messages.service.spec.ts -t 'handles concurrent inserts'
```
Expected: FAIL — Postgres unique-violation thrown to one caller (`23505` error code), test reports unhandled exception or 2 rows.

### Task 1.8: Race recovery (GREEN)

**Files:**
- Modify: `src/modules/messages/services/messages.service.ts`

- [ ] **Step 1: Wrap insert in try/catch with unique-violation recovery**

Locate the `messageRepo.save(...)` (or equivalent INSERT) call in `sendMessage`. Replace:
```typescript
const inserted = await this.messageRepo.save({ ... });
```
with:
```typescript
let inserted: MessageEntity;
try {
  inserted = await this.messageRepo.save({ ... });
} catch (err: any) {
  if (err?.code === '23505' && err?.constraint === 'messages_conv_cmid_unique' && clientMessageId) {
    const existing = await this.messageRepo.findOneOrFail({
      where: { conversationId, clientMessageId },
    });
    return this.toResponseShape(existing);
  }
  throw err;
}
```

- [ ] **Step 2: Run the race test — should now pass**

```bash
pnpm jest --config test/jest-unit.json messages.service.spec.ts -t 'handles concurrent inserts'
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/modules/messages/services/messages.service.ts test/unit/messages.service.spec.ts
git commit -m "feat(messages): recover from unique-violation race on cmid insert

Two concurrent sends with same client_message_id now return the
single inserted row to both callers instead of one of them
crashing on the partial unique index.

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 1.9: WS broadcast carries `client_message_id` (TDD)

**Files:**
- Modify: `test/unit/messages.service.spec.ts`
- Modify: `src/modules/messages/services/messages.service.ts` (broadcast block at line ~1333)

- [ ] **Step 1: Add WS payload test**

```typescript
it('includes client_message_id in WS broadcast payload', async () => {
  const cmid = '33333333-3333-4333-8333-333333333333';
  const conv = await fixtures.createConversation({ participants: ['alice', 'bob'] });

  await service.sendMessage(conv.id, 'alice', 'hi', [], null, undefined, undefined, cmid);

  const event = wsEmitterSpy.mock.calls[0][0][0];  // first emit, first event
  expect(event.event_name).toBe('message:sent');
  expect(event.data.client_message_id).toBe(cmid);
});
```

- [ ] **Step 2: Run — confirm fails**

```bash
pnpm jest --config test/jest-unit.json messages.service.spec.ts -t 'includes client_message_id in WS'
```
Expected: FAIL — payload missing `client_message_id`.

- [ ] **Step 3: Update broadcast emission**

In `messages.service.ts` around line 1333, change:
```typescript
data: { ...sentMessage, topicId: topicIdForPayload }
```
to:
```typescript
data: { ...sentMessage, client_message_id: inserted.clientMessageId, topicId: topicIdForPayload }
```
Apply the same change to the `topic:message` alias broadcast.

- [ ] **Step 4: Run — confirm passes**

```bash
pnpm jest --config test/jest-unit.json messages.service.spec.ts -t 'includes client_message_id in WS'
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/modules/messages/services/messages.service.ts test/unit/messages.service.spec.ts
git commit -m "feat(messages): include client_message_id in WS message:sent broadcast

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 1.10: Validation rejects malformed UUID (TDD)

**Files:**
- Modify: `test/unit/messages.service.spec.ts` OR `test/e2e/messages.e2e-spec.ts` (e2e fits better here since validation runs at the request boundary)

- [ ] **Step 1: Locate or create messages e2e spec**

```bash
ls test/e2e/messages.e2e-spec.ts 2>/dev/null || ls test/integration/messages.spec.ts 2>/dev/null
```
If missing, scaffold from another e2e spec (e.g., copy `test/e2e/auth.e2e-spec.ts` structure if it exists).

- [ ] **Step 2: Add validation test**

```typescript
describe('POST /messages/conversations/:id with client_message_id', () => {
  it('rejects malformed UUID with 400', async () => {
    const conv = await fixtures.createConversation();
    await request(app.getHttpServer())
      .post(`/messages/conversations/${conv.id}`)
      .set('Authorization', `Bearer ${aliceToken}`)
      .send({ body: 'hi', client_message_id: 'not-a-uuid' })
      .expect(400);
  });

  it('accepts valid UUID and returns it in response', async () => {
    const conv = await fixtures.createConversation();
    const cmid = '44444444-4444-4444-8444-444444444444';
    const res = await request(app.getHttpServer())
      .post(`/messages/conversations/${conv.id}`)
      .set('Authorization', `Bearer ${aliceToken}`)
      .send({ body: 'hi', client_message_id: cmid })
      .expect(201);
    expect(res.body.data.client_message_id).toBe(cmid);
  });

  it('accepts requests omitting client_message_id (extension compat)', async () => {
    const conv = await fixtures.createConversation();
    const res = await request(app.getHttpServer())
      .post(`/messages/conversations/${conv.id}`)
      .set('Authorization', `Bearer ${aliceToken}`)
      .send({ body: 'hi' })
      .expect(201);
    expect(res.body.data.client_message_id).toBeNull();
  });
});
```

- [ ] **Step 3: Run e2e**

```bash
pnpm test:e2e --testPathPattern messages
```
Expected: PASS for all three (validation, valid, omitted). The DTO already declares `@IsUUID()` so the failing test was just exercising the contract.

- [ ] **Step 4: Commit**

```bash
git add test/e2e/messages.e2e-spec.ts
git commit -m "test(messages): e2e coverage for client_message_id validation + extension compat

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 1.11: Topic routing preserves cmid (TDD)

**Files:**
- Modify: `test/unit/messages.service.spec.ts`

- [ ] **Step 1: Add topic-routing test**

```typescript
it('persists client_message_id on child-topic message under topicsEnabled conversation', async () => {
  const conv = await fixtures.createConversation({ topicsEnabled: true });
  const cmid = '55555555-5555-4555-8555-555555555555';

  const sent = await service.sendMessage(conv.id, 'alice', 'topic msg', [], null, undefined, undefined, cmid);

  // Routed to General child topic
  expect(sent.topicId).toBeDefined();
  const childRow = await messageRepo.findOneOrFail({
    where: { conversationId: sent.conversation_id, clientMessageId: cmid },
  });
  expect(childRow.clientMessageId).toBe(cmid);
});
```

- [ ] **Step 2: Run**

```bash
pnpm jest --config test/jest-unit.json messages.service.spec.ts -t 'persists client_message_id on child-topic'
```
Expected: PASS (no service changes needed — topic routing already inserts into child conv with all fields).

- [ ] **Step 3: Commit**

```bash
git add test/unit/messages.service.spec.ts
git commit -m "test(messages): cmid preserved through topic auto-routing

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 1.12: BE phase complete — verify and merge readiness

- [ ] **Step 1: Run full test suite**

```bash
cd /Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat-webapp/backend
pnpm test
pnpm test:e2e
```
Expected: green.

- [ ] **Step 2: Run linter**

```bash
pnpm lint
```
Expected: clean.

- [ ] **Step 3: Push branch and open PR**

```bash
git push -u origin feat/issue-88-cmid-roundtrip
gh pr create --title "feat: client_message_id round-trip for message idempotency (#88)" --body "$(cat <<'EOF'
## Summary

Adds optional \`client_message_id\` to the send-message endpoint and \`message:sent\` WS broadcast. Backend dedups by \`(conversation_id, client_message_id)\` via a partial unique index, returning the existing message on retries instead of duplicating.

Implements the BE half of the design in \`gitchat-ios-native/docs/superpowers/specs/2026-04-28-message-reconciliation-client-message-id-design.md\`.

## What changes for clients

- New optional field \`client_message_id\` (uuid) in:
  - \`POST /messages/conversations/:id\` request body
  - HTTP send-message response Message DTO
  - WS \`message:sent\` and \`topic:message\` broadcast payloads
- Clients omitting the field (extension, ShareExtension, old iOS) keep working unchanged.

## Test plan

- [ ] Unit tests: dedup, race recovery, WS payload, topic routing
- [ ] e2e tests: validation, valid send, omitted-field compat
- [ ] Manual: extension send + receive (no cmid) end-to-end
- [ ] Manual: new iOS client send + dedup retry

Refs gitchat-ios-native#88
EOF
)"
```

---

## Phase 2 — iOS frontend

All iOS work happens in `/Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat-ios-native` on branch `feat/issue-88-cmid-roundtrip` (already created and has the spec commit).

### Task 2.1: Add `client_message_id` to `Message` model

**Files:**
- Modify: `GitchatIOS/Core/Networking/models.swift:137` (Message struct)
- Create: `GitchatIOSTests/Models/MessageDecodingTests.swift`

- [ ] **Step 1: Write failing decoding test**

`GitchatIOSTests/Models/MessageDecodingTests.swift`:
```swift
import XCTest
@testable import Gitchat

final class MessageDecodingTests: XCTestCase {
    func test_decodesMessage_withClientMessageId() throws {
        let json = #"""
        {
          "id": "srv-1",
          "client_message_id": "cmid-uuid-1",
          "conversation_id": "conv-1",
          "sender": "alice",
          "content": "hi",
          "created_at": "2026-04-28T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertEqual(msg.client_message_id, "cmid-uuid-1")
    }

    func test_decodesMessage_withoutClientMessageId_legacyPayload() throws {
        let json = #"""
        {
          "id": "srv-2",
          "conversation_id": "conv-1",
          "sender": "alice",
          "content": "hi",
          "created_at": "2026-04-28T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertNil(msg.client_message_id)
    }

    func test_decodesMessage_withNullClientMessageId() throws {
        let json = #"""
        {
          "id": "srv-3",
          "client_message_id": null,
          "conversation_id": "conv-1",
          "sender": "alice",
          "content": "hi",
          "created_at": "2026-04-28T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertNil(msg.client_message_id)
    }
}
```

- [ ] **Step 2: Run — confirm fail**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:GitchatIOSTests/MessageDecodingTests
```
Expected: FAIL with `Value of type 'Message' has no member 'client_message_id'`.

- [ ] **Step 3: Add field to Message struct**

In `models.swift` line ~137, add the property (keep alphabetical or grouped with other ids):
```swift
let client_message_id: String?
```

- [ ] **Step 4: Run — confirm pass**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Core/Networking/models.swift GitchatIOSTests/Models/
git commit -m "feat(ios): add client_message_id to Message model

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.2: Add `clientMessageID` parameter to `APIClient.sendMessage`

**Files:**
- Modify: `GitchatIOS/Core/Networking/APIClient.swift` (sendMessage function around line ~310)
- Create: `GitchatIOSTests/Networking/APIClientSendMessageTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import Gitchat

final class APIClientSendMessageTests: XCTestCase {
    func test_sendMessage_sendsClientMessageIDInBody() async throws {
        let stub = StubURLProtocol.start()
        defer { stub.stop() }

        let cmid = "cmid-test-1"
        _ = try? await APIClient.shared.sendMessage(
            conversationID: "conv-1",
            body: "hi",
            attachments: [],
            replyToID: nil,
            clientMessageID: cmid
        )

        let bodyJSON = try XCTUnwrap(stub.lastRequestBody as? [String: Any])
        XCTAssertEqual(bodyJSON["client_message_id"] as? String, cmid)
    }

    func test_sendMessage_omitsField_whenClientMessageIDNil() async throws {
        let stub = StubURLProtocol.start()
        defer { stub.stop() }

        _ = try? await APIClient.shared.sendMessage(
            conversationID: "conv-1",
            body: "hi",
            attachments: [],
            replyToID: nil,
            clientMessageID: nil
        )

        let bodyJSON = try XCTUnwrap(stub.lastRequestBody as? [String: Any])
        XCTAssertNil(bodyJSON["client_message_id"])
    }
}
```

- [ ] **Step 2: Create `StubURLProtocol` test helper**

`GitchatIOSTests/Helpers/StubURLProtocol.swift`:
```swift
import Foundation

final class StubURLProtocol: URLProtocol {
    static var lastRequestBodyData: Data?
    static var lastRequestBody: Any? {
        guard let data = lastRequestBodyData else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func start() -> Self.Type {
        URLProtocol.registerClass(StubURLProtocol.self)
        return StubURLProtocol.self
    }
    static func stop() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        lastRequestBodyData = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubURLProtocol.lastRequestBodyData = request.httpBody
            ?? request.httpBodyStream.flatMap { Data(reading: $0) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"data\":{\"id\":\"srv\",\"conversation_id\":\"c\",\"sender\":\"a\",\"content\":\"\",\"created_at\":\"2026-04-28T00:00:00Z\"}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open(); defer { stream.close() }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: 4096)
            if n <= 0 { break }
            self.append(buf, count: n)
        }
    }
}
```

- [ ] **Step 3: Run — confirm fail**

Expected: FAIL — `sendMessage` signature has no `clientMessageID` parameter.

- [ ] **Step 4: Update `APIClient.sendMessage`**

In `APIClient.swift` (around the existing `sendMessage` definition near line 310-322), update the signature:
```swift
func sendMessage(
    conversationID: String,
    body: String,
    attachments: [[String: Any]] = [],
    replyToID: String? = nil,
    clientMessageID: String? = nil   // NEW
) async throws -> Message {
    var payload: [String: Any] = ["body": body]
    if !attachments.isEmpty { payload["attachments"] = attachments }
    if let replyToID { payload["reply_to_id"] = replyToID }
    if let clientMessageID { payload["client_message_id"] = clientMessageID }
    // ... existing POST + decode logic
}
```

(If existing call sites use a different signature, adapt — preserve their semantics.)

- [ ] **Step 5: Update existing call sites that call sendMessage**

Search for all callers:
```bash
grep -rn "APIClient.shared.sendMessage" GitchatIOS GitchatShareExtension
```

For each call site, leave existing args as-is (they'll pass `clientMessageID: nil` by default). Only `OutboxStore.executeSend` will need to pass a real value (handled in Task 2.5).

- [ ] **Step 6: Run — confirm pass**

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add GitchatIOS/Core/Networking/APIClient.swift \
        GitchatIOSTests/Networking/ \
        GitchatIOSTests/Helpers/
git commit -m "feat(ios): add clientMessageID parameter to APIClient.sendMessage

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.3: New `PendingAttachment` and `UploadedRef` types

**Files:**
- Modify: `GitchatIOS/Core/OutboxStore.swift`
- Create: `GitchatIOSTests/OutboxStore/PendingAttachmentTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import Gitchat

final class PendingAttachmentTests: XCTestCase {
    func test_init_createsAttachmentWithSourceData_andNilUploaded() {
        let data = Data([0xFF, 0xD8, 0xFF])  // JPEG magic
        let att = PendingAttachment(
            clientAttachmentID: "att-1",
            sourceData: data,
            mimeType: "image/jpeg",
            width: 100, height: 200, blurhash: nil
        )
        XCTAssertEqual(att.clientAttachmentID, "att-1")
        XCTAssertEqual(att.sourceData, data)
        XCTAssertEqual(att.mimeType, "image/jpeg")
        XCTAssertNil(att.uploaded)
    }

    func test_uploadedRef_assignsURL() {
        var att = PendingAttachment(clientAttachmentID: "att-1", sourceData: Data(), mimeType: "image/png", width: nil, height: nil, blurhash: nil)
        att.uploaded = UploadedRef(url: "https://cdn/x.png", storagePath: "p/x.png", sizeBytes: 1024)
        XCTAssertEqual(att.uploaded?.url, "https://cdn/x.png")
    }
}
```

- [ ] **Step 2: Run — confirm fail (types not defined)**

Expected: FAIL.

- [ ] **Step 3: Add types in `OutboxStore.swift`**

Near the existing `PendingMessage` struct, add:
```swift
struct PendingAttachment: Codable, Equatable {
    let clientAttachmentID: String
    var sourceData: Data
    let mimeType: String
    let width: Int?
    let height: Int?
    let blurhash: String?
    var uploaded: UploadedRef?
}

struct UploadedRef: Codable, Equatable {
    let url: String
    let storagePath: String
    let sizeBytes: Int
}
```

- [ ] **Step 4: Run — confirm pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Core/OutboxStore.swift GitchatIOSTests/OutboxStore/
git commit -m "feat(ios): add PendingAttachment + UploadedRef types

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.4: Update `PendingMessage` with new lifecycle and fields

**Files:**
- Modify: `GitchatIOS/Core/OutboxStore.swift` (PendingMessage struct lines 32-48)
- Modify: any internal references to old `localID` and `State`
- Create: `GitchatIOSTests/OutboxStore/PendingMessageTests.swift`

- [ ] **Step 1: Write failing tests for new shape**

```swift
import XCTest
@testable import Gitchat

final class PendingMessageTests: XCTestCase {
    func test_init_textOnly_hasEmptyAttachments() {
        let p = PendingMessage(
            clientMessageID: "cmid-1",
            conversationID: "conv-1",
            content: "hi",
            replyToID: nil,
            attachments: [],
            attempts: 0,
            createdAt: Date(),
            state: .enqueued
        )
        XCTAssertEqual(p.clientMessageID, "cmid-1")
        XCTAssertTrue(p.attachments.isEmpty)
    }

    func test_state_uploadingCarriesProgress() {
        let p = PendingMessage(
            clientMessageID: "cmid-2", conversationID: "c", content: "",
            replyToID: nil, attachments: [],
            attempts: 0, createdAt: Date(),
            state: .uploading(progress: 0.42)
        )
        if case .uploading(let pr) = p.state {
            XCTAssertEqual(pr, 0.42, accuracy: 0.001)
        } else {
            XCTFail("expected uploading state")
        }
    }

    func test_state_failedCarriesReasonAndRetriable() {
        let p = PendingMessage(
            clientMessageID: "cmid-3", conversationID: "c", content: "",
            replyToID: nil, attachments: [],
            attempts: 1, createdAt: Date(),
            state: .failed(reason: "timeout", retriable: true)
        )
        if case .failed(let reason, let retriable) = p.state {
            XCTAssertEqual(reason, "timeout")
            XCTAssertTrue(retriable)
        } else {
            XCTFail("expected failed state")
        }
    }

    func test_optimisticMessageId_derivesFromClientMessageID() {
        XCTAssertEqual(PendingMessage.optimisticID(for: "abc-uuid"), "local-abc-uuid")
    }
}
```

- [ ] **Step 2: Run — confirm fail (old shape)**

Expected: FAIL with shape mismatch.

- [ ] **Step 3: Replace `PendingMessage` and `State`**

In `OutboxStore.swift`, replace the existing struct/enum (lines 32-48) with:
```swift
struct PendingMessage: Codable, Equatable {
    let clientMessageID: String
    let conversationID: String
    var content: String
    var replyToID: String?
    var attachments: [PendingAttachment]
    var attempts: Int
    var createdAt: Date
    var state: State

    static func optimisticID(for clientMessageID: String) -> String {
        "local-\(clientMessageID)"
    }
}

enum State: Equatable, Codable {
    case enqueued
    case uploading(progress: Double)
    case uploaded
    case sending
    case delivered
    case failed(reason: String, retriable: Bool)
}
```

- [ ] **Step 4: Update OutboxStore internals to use new fields**

Inside `OutboxStore.swift`, replace any `pending.localID` with `pending.clientMessageID` (or `PendingMessage.optimisticID(for:)`). Update any `case .sending` / `case .failed(message)` patterns to the new associated values.

- [ ] **Step 5: Build to surface call-site fallout**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 16' build
```
Expected: errors at any code referencing the removed `localID` or old `State`. Note each, fix in-place, rebuild.

- [ ] **Step 6: Run new tests — confirm pass**

```bash
xcodebuild test ... -only-testing:GitchatIOSTests/PendingMessageTests
```
Expected: PASS.

- [ ] **Step 7: Run all unit tests + UITests smoke for regressions**

```bash
xcodebuild test ... -only-testing:GitchatIOSTests
```
Expected: green.

- [ ] **Step 8: Commit**

```bash
git add GitchatIOS/Core/OutboxStore.swift GitchatIOSTests/OutboxStore/
git commit -m "feat(ios): redesign PendingMessage with cmid + lifecycle FSM

Replaces localID with clientMessageID, expands State to cover
the upload/send pipeline (enqueued, uploading, uploaded,
sending, delivered, failed(retriable)).

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.5: `OutboxStore.executeSend` — text-only path (TDD)

**Files:**
- Modify: `GitchatIOS/Core/OutboxStore.swift` (`executeSend` private method)
- Create: `GitchatIOSTests/OutboxStore/OutboxStoreLifecycleTests.swift`

- [ ] **Step 1: Write failing test for text-only happy path**

```swift
import XCTest
@testable import Gitchat

@MainActor
final class OutboxStoreLifecycleTests: XCTestCase {
    func test_textOnly_skipsUploading_endsInDelivered_invokesHandler() async throws {
        let store = OutboxStore(api: MockAPIClient.textSucceeds())
        let convId = "conv-1"
        let cmid = "cmid-text-1"
        var delivered: Message?
        store.registerDeliveryHandler(conversationID: convId) { delivered = $0 }

        store.enqueue(PendingMessage(
            clientMessageID: cmid, conversationID: convId,
            content: "hello", replyToID: nil, attachments: [],
            attempts: 0, createdAt: Date(), state: .enqueued
        ))

        try await store.waitUntilIdle(timeout: 2.0)

        XCTAssertEqual(delivered?.client_message_id, cmid)
        XCTAssertNil(store.pending(conversationID: convId).first { $0.clientMessageID == cmid },
                     "delivered messages should be removed from queue")
    }
}
```

- [ ] **Step 2: Create `MockAPIClient` helper**

`GitchatIOSTests/Helpers/MockAPIClient.swift`:
```swift
import Foundation
@testable import Gitchat

final class MockAPIClient: APIClientProtocol {
    static func textSucceeds() -> MockAPIClient {
        let m = MockAPIClient()
        m.sendStub = { conversationID, body, attachments, replyToID, cmid in
            Message(
                id: "srv-\(cmid ?? UUID().uuidString)",
                client_message_id: cmid,
                conversation_id: conversationID,
                sender: "alice",
                content: body,
                created_at: ISO8601DateFormatter().string(from: Date())
                // ... fill required Message fields with test defaults
            )
        }
        return m
    }

    var sendStub: ((String, String, [[String: Any]], String?, String?) async throws -> Message)!
    func sendMessage(conversationID: String, body: String, attachments: [[String: Any]], replyToID: String?, clientMessageID: String?) async throws -> Message {
        try await sendStub(conversationID, body, attachments, replyToID, clientMessageID)
    }

    var uploadStub: ((Data, String) async throws -> UploadedRef)!
    func uploadAttachment(conversationID: String, data: Data, mimeType: String) async throws -> UploadedRef {
        try await uploadStub(data, mimeType)
    }
}
```

- [ ] **Step 3: Introduce `APIClientProtocol`**

In `GitchatIOS/Core/Networking/APIClient.swift`, extract a protocol the store depends on:
```swift
protocol APIClientProtocol {
    func sendMessage(conversationID: String, body: String, attachments: [[String: Any]], replyToID: String?, clientMessageID: String?) async throws -> Message
    func uploadAttachment(conversationID: String, data: Data, mimeType: String) async throws -> UploadedRef
}

extension APIClient: APIClientProtocol {}
```

- [ ] **Step 4: Update `OutboxStore` to accept injected `APIClientProtocol`**

Add to OutboxStore:
```swift
private let api: APIClientProtocol
init(api: APIClientProtocol = APIClient.shared) { self.api = api }
static let shared = OutboxStore()
```

Replace `APIClient.shared.sendMessage(...)` calls inside `executeSend` with `api.sendMessage(...)`.

- [ ] **Step 5: Implement text-only `executeSend` path**

```swift
@MainActor
private func executeSend(_ pending: PendingMessage) async {
    var p = pending

    // Phase 1: upload (skip if no attachments)
    if !p.attachments.isEmpty {
        // ... handled in Task 2.6
    }

    // Phase 2: send
    p.state = .sending; update(p)
    do {
        let serverMsg = try await api.sendMessage(
            conversationID: p.conversationID,
            body: p.content,
            attachments: p.attachments.compactMap { $0.uploaded.map { ["url": $0.url, "storage_path": $0.storagePath] } },
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

private func isRetriableError(_ error: Error) -> Bool {
    // urlError.networkUnavailable, .timedOut, etc., or HTTP 5xx
    if let urlError = error as? URLError {
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(urlError.code)
    }
    if let apiError = error as? APIError, apiError.statusCode >= 500 { return true }
    return false
}
```

- [ ] **Step 6: Add `waitUntilIdle` test helper on OutboxStore**

Inside `OutboxStore.swift`:
```swift
#if DEBUG
@MainActor
func waitUntilIdle(timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if pendingMessages.values.allSatisfy({ $0.allSatisfy { isTerminal($0.state) } }) { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw XCTestError(.timeoutWhileWaiting)
}

private func isTerminal(_ state: State) -> Bool {
    if case .delivered = state { return true }
    if case .failed(_, retriable: false) = state { return true }
    return false
}
#endif
```

- [ ] **Step 7: Run test — confirm pass**

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add GitchatIOS/Core/OutboxStore.swift \
        GitchatIOS/Core/Networking/APIClient.swift \
        GitchatIOSTests/OutboxStore/ \
        GitchatIOSTests/Helpers/MockAPIClient.swift
git commit -m "feat(ios): OutboxStore lifecycle for text-only sends

Adds APIClientProtocol injection, FSM-driven executeSend, and
delivery-handler invocation with client_message_id.

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.6: `OutboxStore.executeSend` — upload phase (TDD)

**Files:**
- Modify: `GitchatIOS/Core/OutboxStore.swift` (`executeSend`)
- Modify: `GitchatIOSTests/OutboxStore/OutboxStoreLifecycleTests.swift`

- [ ] **Step 1: Write failing test**

Add to `OutboxStoreLifecycleTests`:
```swift
func test_withAttachments_transitions_uploading_uploaded_sending_delivered() async throws {
    let mock = MockAPIClient()
    var observedStates: [State] = []
    mock.uploadStub = { _, _ in
        try await Task.sleep(nanoseconds: 50_000_000)
        return UploadedRef(url: "https://cdn/img.jpg", storagePath: "p/img.jpg", sizeBytes: 1024)
    }
    mock.sendStub = { conv, body, atts, _, cmid in
        Message(id: "srv-1", client_message_id: cmid, conversation_id: conv, sender: "alice", content: body, created_at: ISO8601DateFormatter().string(from: Date()))
    }

    let store = OutboxStore(api: mock)
    store.observeState { observedStates.append($0) }

    let cmid = "cmid-img-1"
    let att = PendingAttachment(clientAttachmentID: "a1", sourceData: Data([0xFF]), mimeType: "image/jpeg", width: nil, height: nil, blurhash: nil)
    store.enqueue(PendingMessage(
        clientMessageID: cmid, conversationID: "c", content: "caption",
        replyToID: nil, attachments: [att],
        attempts: 0, createdAt: Date(), state: .enqueued
    ))

    try await store.waitUntilIdle(timeout: 2.0)

    XCTAssertEqual(
        observedStates.map { $0.kind },
        [.enqueued, .uploading, .uploaded, .sending, .delivered]
    )
}
```

(Add `State.kind` extension returning a stable `enum Kind { case enqueued, uploading, uploaded, sending, delivered, failed }` for ordering assertions.)

- [ ] **Step 2: Run — confirm fail**

Expected: FAIL — upload path not implemented.

- [ ] **Step 3: Implement Phase 1 of `executeSend`**

Inside `executeSend`, before the existing Phase 2 send block:
```swift
if !p.attachments.isEmpty && p.attachments.contains(where: { $0.uploaded == nil }) {
    p.state = .uploading(progress: 0.0); update(p)
    let total = Double(p.attachments.count)
    var done = 0.0
    for i in p.attachments.indices where p.attachments[i].uploaded == nil {
        do {
            let ref = try await api.uploadAttachment(
                conversationID: p.conversationID,
                data: p.attachments[i].sourceData,
                mimeType: p.attachments[i].mimeType
            )
            p.attachments[i].uploaded = ref
            done += 1
            p.state = .uploading(progress: done / total)
            update(p)
        } catch {
            p.attempts += 1
            let retriable = isRetriableError(error) && p.attempts < 5
            p.state = .failed(reason: "Upload failed: \(error)", retriable: retriable)
            update(p)
            if retriable { scheduleRetry(p) }
            return
        }
    }
    p.state = .uploaded; update(p)
}
```

When sending in Phase 2 with attachments, build the JSON list from `p.attachments.compactMap { $0.uploaded }`.

- [ ] **Step 4: Run — confirm pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Core/OutboxStore.swift GitchatIOSTests/OutboxStore/
git commit -m "feat(ios): OutboxStore handles upload phase before send

Sequential per-attachment upload with progress reporting.
Failure transitions to failed(retriable) and triggers backoff.

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.7: Retry & backoff (TDD)

**Files:**
- Modify: `GitchatIOS/Core/OutboxStore.swift`
- Modify: `GitchatIOSTests/OutboxStore/OutboxStoreLifecycleTests.swift`

- [ ] **Step 1: Write failing test**

```swift
func test_serverReturns500_retriesWithBackoff_eventuallyDelivers() async throws {
    let mock = MockAPIClient()
    var attempts = 0
    mock.sendStub = { conv, body, _, _, cmid in
        attempts += 1
        if attempts < 3 { throw APIError(statusCode: 500, message: "internal") }
        return Message(id: "srv-1", client_message_id: cmid, conversation_id: conv, sender: "alice", content: body, created_at: ISO8601DateFormatter().string(from: Date()))
    }
    let store = OutboxStore(api: mock, retryClock: ImmediateClock())

    var delivered: Message?
    store.registerDeliveryHandler(conversationID: "c") { delivered = $0 }
    store.enqueue(PendingMessage(clientMessageID: "cmid-r", conversationID: "c", content: "x", replyToID: nil, attachments: [], attempts: 0, createdAt: Date(), state: .enqueued))

    try await store.waitUntilIdle(timeout: 5.0)

    XCTAssertEqual(attempts, 3)
    XCTAssertNotNil(delivered)
}

func test_serverReturns400_doesNotRetry_stateFailedNotRetriable() async throws {
    let mock = MockAPIClient()
    mock.sendStub = { _, _, _, _, _ in throw APIError(statusCode: 400, message: "bad input") }
    let store = OutboxStore(api: mock, retryClock: ImmediateClock())

    let cmid = "cmid-bad"
    store.enqueue(PendingMessage(clientMessageID: cmid, conversationID: "c", content: "x", replyToID: nil, attachments: [], attempts: 0, createdAt: Date(), state: .enqueued))

    try await store.waitUntilIdle(timeout: 1.0)

    let p = store.pending(conversationID: "c").first { $0.clientMessageID == cmid }!
    if case .failed(_, let retriable) = p.state {
        XCTAssertFalse(retriable)
    } else { XCTFail("expected failed state") }
}
```

- [ ] **Step 2: Add `RetryClock` abstraction**

```swift
protocol RetryClock { func sleep(seconds: Double) async throws }
struct RealRetryClock: RetryClock { func sleep(seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } }
struct ImmediateClock: RetryClock { func sleep(seconds: Double) async throws {} }
```

Inject into OutboxStore: `init(api: ..., retryClock: RetryClock = RealRetryClock())`.

- [ ] **Step 3: Implement `scheduleRetry`**

```swift
private func scheduleRetry(_ pending: PendingMessage) {
    let delay = backoffSeconds(forAttempt: pending.attempts)  // 2,4,8,16,32
    Task { @MainActor in
        try? await retryClock.sleep(seconds: delay)
        var p = pending
        p.state = .enqueued
        update(p)
        runSend(conversationID: p.conversationID)
    }
}

private func backoffSeconds(forAttempt n: Int) -> Double {
    return min(pow(2.0, Double(n + 1)), 32.0)  // 2,4,8,16,32
}
```

- [ ] **Step 4: Run tests — confirm pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Core/OutboxStore.swift GitchatIOSTests/OutboxStore/
git commit -m "feat(ios): OutboxStore retry with exponential backoff

5xx and network errors trigger up to 5 retries with 2,4,8,16,32s
backoff. 4xx errors mark message failed(retriable: false).

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.8: Cancel V1 (TDD)

**Files:**
- Modify: `GitchatIOS/Core/OutboxStore.swift`
- Modify: `GitchatIOSTests/OutboxStore/OutboxStoreLifecycleTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
func test_cancel_removesEnqueuedMessage() {
    let store = OutboxStore(api: MockAPIClient.textSucceeds())
    let cmid = "cmid-cancel-1"
    store.enqueue(PendingMessage(clientMessageID: cmid, conversationID: "c", content: "x", replyToID: nil, attachments: [], attempts: 0, createdAt: Date(), state: .enqueued))

    store.cancel(clientMessageID: cmid)

    XCTAssertNil(store.pending(conversationID: "c").first { $0.clientMessageID == cmid })
}

func test_cancel_isNoOp_whenStateIsUploadingOrSending() async throws {
    let mock = MockAPIClient()
    mock.uploadStub = { _, _ in
        try await Task.sleep(nanoseconds: 200_000_000)
        return UploadedRef(url: "u", storagePath: "p", sizeBytes: 1)
    }
    mock.sendStub = { c, b, _, _, cmid in Message(id: "srv", client_message_id: cmid, conversation_id: c, sender: "a", content: b, created_at: "2026-01-01T00:00:00Z") }

    let store = OutboxStore(api: mock, retryClock: ImmediateClock())
    let cmid = "cmid-cancel-2"
    store.enqueue(PendingMessage(clientMessageID: cmid, conversationID: "c", content: "x", replyToID: nil,
        attachments: [PendingAttachment(clientAttachmentID: "a", sourceData: Data(), mimeType: "image/jpeg", width: nil, height: nil, blurhash: nil)],
        attempts: 0, createdAt: Date(), state: .enqueued))

    // Wait until state transitions to uploading
    try await store.waitForState(cmid: cmid, kind: .uploading, timeout: 1.0)
    store.cancel(clientMessageID: cmid)
    let p = store.pending(conversationID: "c").first { $0.clientMessageID == cmid }
    XCTAssertNotNil(p, "cancel must be no-op while uploading")
}
```

- [ ] **Step 2: Implement `cancel` and `waitForState`**

```swift
@MainActor
func cancel(clientMessageID cmid: String) {
    for (convId, list) in pendingMessages {
        if let idx = list.firstIndex(where: { $0.clientMessageID == cmid }) {
            switch list[idx].state {
            case .enqueued, .failed:
                pendingMessages[convId]?.remove(at: idx)
            case .uploading, .uploaded, .sending, .delivered:
                return  // V1: no-op
            }
            return
        }
    }
}

#if DEBUG
@MainActor
func waitForState(cmid: String, kind: State.Kind, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let p = allPending().first(where: { $0.clientMessageID == cmid }), p.state.kind == kind { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw XCTestError(.timeoutWhileWaiting)
}
#endif
```

- [ ] **Step 3: Run — confirm pass**

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add GitchatIOS/Core/OutboxStore.swift GitchatIOSTests/OutboxStore/
git commit -m "feat(ios): OutboxStore cancel — V1 only enqueued/failed

In-flight uploads/sends cannot be cancelled in V1; UI button
must be disabled outside terminal-or-enqueued states.

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.9: `ChatViewModel.send` unified entry point (TDD)

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift`
- Create: `GitchatIOSTests/Conversations/ChatViewModelSendTests.swift`

- [ ] **Step 1: Write failing test**

```swift
@MainActor
final class ChatViewModelSendTests: XCTestCase {
    func test_send_appendsOptimisticMessage_andEnqueuesPending() {
        let store = OutboxStore(api: MockAPIClient.deferred())
        let vm = ChatViewModel.testInstance(outbox: store)

        vm.send(content: "hi")

        XCTAssertEqual(vm.messages.count, 1)
        let opt = vm.messages.first!
        XCTAssertTrue(opt.id.hasPrefix("local-"))
        XCTAssertNotNil(opt.client_message_id)
        XCTAssertEqual(opt.id, "local-\(opt.client_message_id!)")

        let queued = store.pending(conversationID: vm.conversation.id).first
        XCTAssertEqual(queued?.clientMessageID, opt.client_message_id)
        XCTAssertEqual(queued?.content, "hi")
    }

    func test_send_withAttachments_passesPendingAttachments() {
        let store = OutboxStore(api: MockAPIClient.deferred())
        let vm = ChatViewModel.testInstance(outbox: store)
        let att = PendingAttachment(clientAttachmentID: "a", sourceData: Data([0xFF]), mimeType: "image/jpeg", width: 100, height: 200, blurhash: nil)

        vm.send(content: "look", attachments: [att])

        let queued = store.pending(conversationID: vm.conversation.id).first!
        XCTAssertEqual(queued.attachments.count, 1)
        XCTAssertEqual(queued.attachments.first?.clientAttachmentID, "a")
    }

    func test_send_withEmptyContentAndNoAttachments_noOp() {
        let store = OutboxStore(api: MockAPIClient.deferred())
        let vm = ChatViewModel.testInstance(outbox: store)
        vm.send(content: "", attachments: [])
        XCTAssertEqual(vm.messages.count, 0)
        XCTAssertEqual(store.pending(conversationID: vm.conversation.id).count, 0)
    }
}
```

- [ ] **Step 2: Run — confirm fail**

Expected: FAIL — `send(content:attachments:replyTo:)` and `ChatViewModel.testInstance(outbox:)` don't exist.

- [ ] **Step 3: Add unified `send` method**

In `ChatViewModel.swift`:
```swift
@MainActor
func send(content: String, attachments: [PendingAttachment] = [], replyTo: Message? = nil) {
    guard !content.isEmpty || !attachments.isEmpty else { return }
    let cmid = UUID().uuidString
    let optimistic = Message.optimistic(
        clientMessageID: cmid,
        conversationID: conversation.id,
        sender: auth.login,
        content: content,
        attachments: attachments
    )
    messages.append(optimistic)
    persistCache()
    outbox.enqueue(PendingMessage(
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

Add `Message.optimistic(...)` static factory in `models.swift` populating fields with defaults.

Inject `outbox: OutboxStore` into `ChatViewModel.init` (default `.shared`). Add `static func testInstance(outbox: OutboxStore) -> ChatViewModel` returning a VM with stubbed conversation + auth.

- [ ] **Step 4: Run — confirm pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift \
        GitchatIOS/Core/Networking/models.swift \
        GitchatIOSTests/Conversations/
git commit -m "feat(ios): ChatViewModel unified send entry point

Single send(content:attachments:replyTo:) creates optimistic
message with cmid and enqueues to OutboxStore. Replaces direct
upload/send code paths from previous design.

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.10: `ChatViewModel.mergeFromServer` (TDD)

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift` (existing `load` and `loadMoreIfNeeded` use a merge step)
- Create: `GitchatIOSTests/Conversations/MergeFromServerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
@MainActor
final class MergeFromServerTests: XCTestCase {
    func test_serverMessage_replacesOptimistic_byClientMessageID() {
        let vm = ChatViewModel.testInstance(outbox: OutboxStore(api: MockAPIClient.deferred()))
        let cmid = "cmid-1"
        let opt = Message.optimistic(clientMessageID: cmid, conversationID: vm.conversation.id, sender: "a", content: "hi", attachments: [])
        vm.messages = [opt]

        let srv = Message(id: "srv-1", client_message_id: cmid, conversation_id: vm.conversation.id, sender: "a", content: "hi", created_at: "2026-04-28T00:00:00Z")
        vm.mergeFromServer([srv])

        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.id, "srv-1")
    }

    func test_serverMessage_appendedWhenNoMatch() {
        let vm = ChatViewModel.testInstance(outbox: OutboxStore(api: MockAPIClient.deferred()))
        vm.messages = []
        let srv = Message(id: "srv-2", client_message_id: nil, conversation_id: vm.conversation.id, sender: "b", content: "yo", created_at: "2026-04-28T00:00:00Z")
        vm.mergeFromServer([srv])
        XCTAssertEqual(vm.messages.map(\.id), ["srv-2"])
    }

    func test_orphanLocalCmid_cleanedWhenServerArrivesUnderDifferentBranch() {
        let vm = ChatViewModel.testInstance(outbox: OutboxStore(api: MockAPIClient.deferred()))
        let cmid = "cmid-orph"
        let opt = Message.optimistic(clientMessageID: cmid, conversationID: vm.conversation.id, sender: "a", content: "x", attachments: [])
        vm.messages = [opt]

        let srv = Message(id: "srv-orph", client_message_id: cmid, conversation_id: vm.conversation.id, sender: "a", content: "x", created_at: "2026-04-28T00:00:00Z")
        vm.mergeFromServer([srv])

        XCTAssertFalse(vm.messages.contains(where: { $0.id == "local-\(cmid)" }))
        XCTAssertTrue(vm.messages.contains(where: { $0.id == "srv-orph" }))
    }

    func test_legacyLocalWithoutCmid_isCleanedOnNextLoad() {
        let vm = ChatViewModel.testInstance(outbox: OutboxStore(api: MockAPIClient.deferred()))
        let legacy = Message(id: "local-legacy", client_message_id: nil, conversation_id: vm.conversation.id, sender: "a", content: "x", created_at: "2026-04-28T00:00:00Z")
        vm.messages = [legacy]
        vm.mergeFromServer([])  // no server messages
        XCTAssertEqual(vm.messages.count, 0, "legacy local-* without cmid should be cleaned")
    }
}
```

- [ ] **Step 2: Run — confirm fail**

Expected: FAIL — `mergeFromServer` doesn't exist; existing merge is inline in `load`.

- [ ] **Step 3: Extract and replace merge logic**

In `ChatViewModel.swift`, factor out the merge logic from `load()` and `loadMoreIfNeeded()` into:
```swift
@MainActor
func mergeFromServer(_ fetched: [Message]) {
    var existing = self.messages
    for srv in fetched {
        if let cmid = srv.client_message_id,
           let idx = existing.firstIndex(where: { $0.client_message_id == cmid }) {
            existing[idx] = srv; continue
        }
        if let idx = existing.firstIndex(where: { $0.id == srv.id }) {
            existing[idx] = srv; continue
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

Update `load()` (line ~104) and `loadMoreIfNeeded()` (line ~150) to call `mergeFromServer(fetched)` instead of doing it inline.

- [ ] **Step 4: Run — confirm pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift GitchatIOSTests/Conversations/
git commit -m "feat(ios): ChatViewModel.mergeFromServer matches by client_message_id

Replaces inline id-only merge with cmid-aware merge that cleans
orphan local-* placeholders when the server message arrives.

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.11: `MessageCache` filter on save & load (TDD)

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift` (`persistCache` + init)
- Create: `GitchatIOSTests/Conversations/MessageCacheFilterTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
@MainActor
final class MessageCacheFilterTests: XCTestCase {
    func test_persistCache_excludesLocalPrefixedMessages() {
        let vm = ChatViewModel.testInstance(outbox: OutboxStore(api: MockAPIClient.deferred()))
        let local = Message.optimistic(clientMessageID: "x", conversationID: vm.conversation.id, sender: "a", content: "opt", attachments: [])
        let server = Message(id: "srv-y", client_message_id: nil, conversation_id: vm.conversation.id, sender: "a", content: "real", created_at: "t")
        vm.messages = [local, server]

        vm.persistCache()

        let stored = MessageCache.shared.get(vm.conversation.id)
        XCTAssertEqual(stored?.messages.map(\.id), ["srv-y"])
    }

    func test_init_filtersLocalPrefixedMessagesFromCache() {
        let conv = Conversation.testFixture()
        let local = Message(id: "local-junk", client_message_id: "x", conversation_id: conv.id, sender: "a", content: "junk", created_at: "t")
        let real = Message(id: "srv-real", client_message_id: nil, conversation_id: conv.id, sender: "a", content: "ok", created_at: "t")
        MessageCache.shared.store(conv.id, entry: MessageCache.Entry(messages: [local, real], nextCursor: nil, otherReadAt: nil, readCursors: nil, fetchedAt: Date()))

        let vm = ChatViewModel(conversation: conv, auth: .testFixture(), outbox: OutboxStore(api: MockAPIClient.deferred()))
        XCTAssertEqual(vm.messages.map(\.id), ["srv-real"])
    }
}
```

- [ ] **Step 2: Run — confirm fail**

Expected: FAIL — both filters not in place.

- [ ] **Step 3: Apply both filters**

In `ChatViewModel.persistCache` (line 157), change:
```swift
messages: self.messages,
```
to:
```swift
messages: self.messages.filter { !$0.id.hasPrefix("local-") },
```

In `ChatViewModel.init` (line 27), change:
```swift
self.messages = cached.messages
```
to:
```swift
self.messages = cached.messages.filter { !$0.id.hasPrefix("local-") }
```

- [ ] **Step 4: Run — confirm pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift GitchatIOSTests/Conversations/
git commit -m "fix(ios): filter local-* messages on cache save AND load

Defense in depth for bug #5 — prevents new leaks on save and
cleans existing dirty caches on load.

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.12: `SocketClient.onMessageSent` and OutboxStore deliveryHandler match by cmid (TDD)

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetailView.swift` (lines 718-733 — both handlers)
- Create: `GitchatIOSTests/Conversations/SocketHandlerMatchingTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
@MainActor
final class SocketHandlerMatchingTests: XCTestCase {
    func test_inboundMessage_withMatchingCmid_replacesOptimistic() {
        let store = OutboxStore(api: MockAPIClient.deferred())
        let vm = ChatViewModel.testInstance(outbox: store)
        let cmid = "cmid-w"
        vm.messages = [Message.optimistic(clientMessageID: cmid, conversationID: vm.conversation.id, sender: "a", content: "x", attachments: [])]

        let handler = ChatDetailViewBindings.makeSocketMessageSentHandler(vm: vm)
        let inbound = Message(id: "srv-w", client_message_id: cmid, conversation_id: vm.conversation.id, sender: "a", content: "x", created_at: "t")
        handler(inbound)

        XCTAssertEqual(vm.messages.map(\.id), ["srv-w"])
    }

    func test_inboundMessage_noMatch_appendsViaSeenIdsDedup() {
        ChatMessageView.seenIds.removeAll()
        let vm = ChatViewModel.testInstance(outbox: OutboxStore(api: MockAPIClient.deferred()))
        vm.messages = []

        let handler = ChatDetailViewBindings.makeSocketMessageSentHandler(vm: vm)
        let m1 = Message(id: "srv-A", client_message_id: nil, conversation_id: vm.conversation.id, sender: "b", content: "yo", created_at: "t")
        handler(m1); handler(m1)

        XCTAssertEqual(vm.messages.count, 1)  // seenIds dedup blocks duplicate
    }
}
```

- [ ] **Step 2: Extract handler factory**

Move the closure body out of `ChatDetailView.body` into a testable helper:

`GitchatIOS/Features/Conversations/ChatDetail/ChatDetailViewBindings.swift`:
```swift
import Foundation

@MainActor
enum ChatDetailViewBindings {
    static func makeSocketMessageSentHandler(vm: ChatViewModel) -> (Message) -> Void {
        return { msg in
            guard msg.conversation_id == vm.conversation.id else { return }
            if let cmid = msg.client_message_id,
               let idx = vm.messages.firstIndex(where: { $0.client_message_id == cmid }) {
                vm.messages[idx] = msg
                ChatMessageView.seenIds.insert(msg.id)
                return
            }
            guard ChatMessageView.seenIds.insert(msg.id).inserted else { return }
            vm.messages.append(msg)
        }
    }

    static func makeOutboxDeliveryHandler(vm: ChatViewModel) -> (Message) -> Void {
        return { msg in
            if let cmid = msg.client_message_id,
               let idx = vm.messages.firstIndex(where: { $0.client_message_id == cmid }) {
                vm.messages[idx] = msg
                ChatMessageView.seenIds.insert(msg.id)
                return
            }
            guard ChatMessageView.seenIds.insert(msg.id).inserted else { return }
            vm.messages.append(msg)
        }
    }
}
```

- [ ] **Step 3: Replace closures in `ChatDetailView`**

In `ChatDetailView.swift` lines 718-733:
```swift
OutboxStore.shared.registerDeliveryHandler(
    conversationID: vm.conversation.id,
    ChatDetailViewBindings.makeOutboxDeliveryHandler(vm: vm)
)
socket.onMessageSent = ChatDetailViewBindings.makeSocketMessageSentHandler(vm: vm)
```

Note: keep the side-effect of `markRead` for non-self messages — add it inside the bindings factory if it was there before.

- [ ] **Step 4: Run — confirm pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/ChatDetailViewBindings.swift \
        GitchatIOS/Features/Conversations/ChatDetailView.swift \
        GitchatIOSTests/Conversations/
git commit -m "feat(ios): WS + Outbox handlers match by client_message_id

Outbound dedup via cmid replaces dual-id coordination. Inbound
seenIds dedup preserved for messages without cmid (other senders).

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.13: Remove old upload/send methods from `ChatViewModel`

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift`
- Modify: any callers of `uploadAndSend`, `sendEncodedAttachments`, `uploadImagesAndSend`

- [ ] **Step 1: Find all call sites**

```bash
grep -rn "uploadAndSend\|sendEncodedAttachments\|uploadImagesAndSend" GitchatIOS GitchatShareExtension
```

- [ ] **Step 2: Replace each call site with `vm.send(content:attachments:)`**

For paste-image flow (`ChatDetailView`), composer flow, etc.:
- Convert UIImage → JPEG `Data` (existing code does this)
- Build `[PendingAttachment]` from data + MIME
- Call `vm.send(content: caption, attachments: pendingAttachments)`

(If the existing call site was expecting an `await` on `uploadAndSend`, drop the await — `vm.send` returns synchronously; the OutboxStore handles async work.)

- [ ] **Step 3: Delete the three methods from `ChatViewModel`**

Remove `uploadAndSend(...)`, `sendEncodedAttachments(...)`, `uploadImagesAndSend(...)` and any private helpers used only by them.

- [ ] **Step 4: Build to surface stale references**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS -destination 'platform=iOS Simulator,name=iPhone 16' build
```
Fix any compile errors.

- [ ] **Step 5: Run all unit tests + smoke**

```bash
xcodebuild test ... -only-testing:GitchatIOSTests
xcodebuild test ... -only-testing:GitchatIOSUITests/SmokeTests
```
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add GitchatIOS/Features/Conversations/ChatDetail/ChatViewModel.swift \
        GitchatIOS/Features/Conversations/ChatDetailView.swift
git commit -m "refactor(ios): drop uploadAndSend/sendEncodedAttachments/uploadImagesAndSend

All sends now flow through ChatViewModel.send → OutboxStore.

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.14: ShareExtension audit (no behavior change)

**Files:**
- Read: `GitchatShareExtension/ShareViewController.swift` (or its API call site)

- [ ] **Step 1: Locate ShareExtension's send call**

```bash
grep -rn "sendMessage\|sendAttachment\|messages/conversations" GitchatShareExtension/
```

- [ ] **Step 2: Verify it still compiles after `APIClient.sendMessage` signature change**

Since `clientMessageID` defaults to `nil`, ShareExtension's existing call sites should still compile. If any are positional and now break, add explicit `clientMessageID: nil` argument or named-arg refactor.

- [ ] **Step 3: Build the ShareExtension target**

```bash
xcodebuild -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -target GitchatShareExtension build
```
Expected: green.

- [ ] **Step 4: No-op commit if no changes; otherwise commit fixups**

If diffs exist:
```bash
git add GitchatShareExtension/
git commit -m "chore(share-extension): align with new APIClient.sendMessage signature

ShareExtension passes clientMessageID: nil — keeps current
non-idempotent behavior, future work tracked separately.

Refs #88

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2.15: iOS phase complete — full test suite

- [ ] **Step 1: Run all unit tests**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:GitchatIOSTests
```
Expected: all tests pass.

- [ ] **Step 2: Run UI smoke tests**

```bash
xcodebuild test \
  -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:GitchatIOSUITests/SmokeTests
```
Expected: green.

- [ ] **Step 3: Run paste-image regression**

```bash
xcodebuild test ... -only-testing:GitchatIOSUITests/PasteImageFromClipboardTests
```
Expected: green (regression check from previous spec).

---

## Phase 3 — End-to-end manual verification

These checks require a running BE deploy + a fresh iOS build. Execute against the dev environment.

### Task 3.1: Stress paste regression (bug #1, already patched)

- [ ] Open a chat
- [ ] Paste 5 images in <2 seconds (Cmd+V on Mac Catalyst, or simulator paste)
- [ ] Send each
- [ ] **Expected:** 0 crashes, 0 duplicate bubbles. All 5 images render.

### Task 3.2: Back-out + re-enter mid-upload (bug #2)

- [ ] Open chat A
- [ ] Paste a large image (>2MB), tap Send
- [ ] While the bubble is still in `uploading` (spinner visible), navigate back to chat list
- [ ] Wait 5 seconds (let upload + send complete in background)
- [ ] Re-open chat A
- [ ] **Expected:** the image bubble shows server id (no spinner), one copy. No stuck `local-*`.

### Task 3.3: Force-quit mid-upload

- [ ] Open chat A
- [ ] Paste a large image, tap Send
- [ ] During `uploading`, force-quit the app (swipe up)
- [ ] Re-launch the app, open chat A
- [ ] **Expected:** the optimistic bubble is gone (filtered on cache load). No ghost. If the upload had reached BE before kill, the message arrives via `vm.load()`.

### Task 3.4: Image + caption send (bug #3)

- [ ] Open chat A
- [ ] Type "look at this" in the composer
- [ ] Paste 2 images
- [ ] Tap Send
- [ ] **Expected:** ONE bubble containing the caption + 2 images. Same on receiver. Same order.

### Task 3.5: Cache leak cleanup (bug #5)

- [ ] On a device with the OLD app, paste an image and force-quit before send completes (creates leaked `local-*` in cache)
- [ ] Install the NEW build (TestFlight or Xcode Run)
- [ ] Open the same chat
- [ ] **Expected:** the leaked `local-*` is filtered out on cache load; user sees clean message list.

### Task 3.6: Network drop + recover

- [ ] Open chat A, type a long message
- [ ] Enable airplane mode
- [ ] Tap Send
- [ ] **Expected:** bubble shows "sending" → "failed (retriable)" → exponential backoff
- [ ] Disable airplane mode
- [ ] **Expected:** auto-retry succeeds, bubble settles to delivered

### Task 3.7: Double-tap send

- [ ] Open chat A
- [ ] Type a message
- [ ] Double-tap Send rapidly (try to fire 2 sends)
- [ ] **Expected:** ONE bubble. BE dedup may have hit; verify only 1 row in DB for that conversation around that timestamp.

### Task 3.8: Receive from extension (no cmid in payload)

- [ ] On a second account, send a message via Chrome extension to the iOS user
- [ ] **Expected:** message renders correctly on iOS. `client_message_id == nil` doesn't crash.

### Task 3.9: New iOS → extension receive

- [ ] From iOS, send a text message to a peer who is online via Chrome extension
- [ ] **Expected:** extension renders the message (extension ignores extra `client_message_id` field per Phase 0 verification)

### Task 3.10: Open PR, fill checklist

- [ ] Push iOS branch:
```bash
cd /Users/hieu/Documents/Companies/Lab3/GitstarAI/gitchat-ios-native
git push -u origin feat/issue-88-cmid-roundtrip
```
- [ ] Open PR:
```bash
gh pr create --title "feat(ios): client_message_id round-trip — fix bugs #2, #3, #5 (#88)" --body "$(cat <<'EOF'
## Summary

Implements the iOS half of the client_message_id round-trip design (`docs/superpowers/specs/2026-04-28-message-reconciliation-client-message-id-design.md`).

- **Bug #2**: extended `OutboxStore` lifts upload work out of view-model; back-out + re-enter mid-upload no longer leaves stuck `local-*`.
- **Bug #3**: text + image bundle into one `Message`; receiver sees identical order.
- **Bug #5**: `MessageCache` filters `local-*` on save AND load; existing dirty caches clean themselves on next open.
- New unit-test target `GitchatIOSTests` for FSM and view-model coverage.

## Dependencies

Requires the BE PR (`gitchat-webapp/backend#<NN>`) merged and deployed first. New iOS sends include `client_message_id`; old BE will accept the extra field (no DTO whitelist) but won't dedup.

## Test plan

- [ ] All unit tests pass (`GitchatIOSTests`)
- [ ] UI smoke pass (`SmokeTests`, `PasteImageFromClipboardTests`)
- [ ] Manual: §3.1–§3.9 in plan doc
- [ ] Compatibility: send from extension → iOS receives. Send from iOS → extension receives.

Closes #88
EOF
)"
```

---

## Self-Review (writing-plans skill)

**Spec coverage:**
- §Architecture overview → Tasks 1.4 + 2.1–2.13 implement the diagram
- §Backend → 1.2–1.11
- §OutboxStore extension → 2.4–2.8
- §iOS frontend changes → 2.1–2.13
- §Migration & rollout → 1.2 (DB safety), 1.12 (BE PR), 2.15 + 3.10 (iOS PR), Phase 3 (manual)
- §Testing strategy → covered per task plus Phase 3

**Placeholder scan:** none of TBD/TODO/"add appropriate". Each test step has the actual test code; each implementation step shows the actual code.

**Type consistency:** `clientMessageID` (Swift), `clientMessageId` (TS), `client_message_id` (JSON wire) — used consistently per language convention. `PendingMessage`, `PendingAttachment`, `UploadedRef`, `State.kind` consistent across tasks.

**Open: Section 6 of spec listed several iOS unit tests not explicitly in the plan** (e.g., `test_concurrentEnqueue_serialFIFO_per_conversation`, `test_unregisteredHandler_doesNotCrash`). These are minor coverage adds; if needed, add inside Task 2.5 or 2.7 as additional `it(...)` tests without changing structure.

---

## Execution choice

Plan complete and saved to `docs/superpowers/plans/2026-04-28-message-cmid-roundtrip.md`.

Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach?
