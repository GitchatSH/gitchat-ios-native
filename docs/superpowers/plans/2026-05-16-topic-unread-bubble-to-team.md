# Topic Unread Bubble to Team — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Outer Chats list team row shows an unread badge that includes activity in all of the team's topics, identical to DM/group rows.

**Architecture:** Two coordinated tracks. Backend (Track 1) widens three SQL aggregations in `MessagesService.getConversations` to roll topic rows up to their parent via `COALESCE(parent_conversation_id, self)`. iOS (Track 2) adds a `TopicListStore` publisher that emits parent-unread deltas on every topic mutation, and a `ConversationsViewModel` subscriber that applies them. Wire format is unchanged; non-topic conversations are byte-equal to today.

**Tech Stack:** NestJS 11 + TypeORM + PostgreSQL 15 (backend). SwiftUI + Combine, XCTest (iOS).

**Spec:** `docs/superpowers/specs/2026-05-16-topic-unread-bubble-to-team-design.md`

---

## File Structure

### Backend — `../gitchat-webapp/`

| File | Action |
|---|---|
| `backend/src/modules/messages/services/messages.service.ts` | Modify lines 461-552: add topic-ids preload, expand read-cursor fetch, rewrite 3a/3b/3c queries to group by `effective_parent` |
| `backend/test/unit/modules/messages/messages.service.spec.ts` | Extend: new helper for seeding team+topics with per-conversation cursors; new tests for unread/mentions/reactions bubble, edge cases, DM/group regression |

### iOS — `gitchat-ios-native/`

| File | Action |
|---|---|
| `GitchatIOS/Features/Conversations/Topics/TopicListStore.swift` | Refactor lines 121-209: introduce `ParentUnreadDelta` struct + `parentUnreadDeltas: PassthroughSubject`. Route all three unread-mutation paths through new private helper `setTopicUnread(topicId:parentId:newValue:)` that computes effective delta and publishes |
| `GitchatIOS/Features/Conversations/ConversationsListView.swift` | Modify `ConversationsViewModel` (line 4): add `private var parentUnreadCancellable: AnyCancellable?`, init-time subscription to `TopicListStore.shared.parentUnreadDeltas`, new method `applyParentUnreadDelta(parentId:delta:)` |
| `GitchatIOSTests/Conversations/TopicListStoreParentDeltaTests.swift` | Create: tests for publisher emissions on `bumpUnread`, `clearUnread`, realtime `.message` event, `isActiveSurface` guard |
| `GitchatIOSTests/Conversations/ConversationsViewModelTopicRealtimeTests.swift` | Extend: tests for `applyParentUnreadDelta` (bump, clear, parent-not-in-list no-op, never negative) |
| `GitchatIOSTests/Conversations/ConversationsListRowUnreadBadgeTests.swift` | Create: render-level test asserting `ConversationRow` shows badge accessibility label when `unreadCount = 5` |

---

## Track 1: Backend

> **Test strategy:** Per user decision, tests run against a local Postgres dev DB (no Docker/testcontainers). The codebase has zero existing real-DB test infra, so Task 0 below builds the foundation: a Nest testing module wiring real `DataSource`, a migration runner, and a per-test isolation strategy (transaction rollback). Subsequent tasks (1-5) seed via helpers that share this infrastructure.

### Task 0: Test infrastructure — real-DB integration spec scaffold

**Files:**
- Create: `../gitchat-webapp/backend/test/integration/helpers/db-test-module.ts`
- Create: `../gitchat-webapp/backend/test/integration/helpers/seed-helpers.ts`
- Create: `../gitchat-webapp/backend/test/integration/modules/messages/get-conversations-topic-bubble.integration-spec.ts` (empty smoke test)
- Modify: `../gitchat-webapp/backend/test/jest-e2e.json` (extend `testRegex` to include `.integration-spec.ts`)

- [ ] **Step 1: Add DB-backed Nest testing module helper**

Create `test/integration/helpers/db-test-module.ts`:

```ts
import { Test, TestingModule } from '@nestjs/testing';
import { DataSource } from 'typeorm';
import { TypeOrmModule } from '@nestjs/typeorm';
import * as entities from '@database/postgres/entities';

/**
 * Boot a Nest testing module bound to the local dev Postgres.
 * Requires DATABASE_URL or the standard PG* env vars in `.env`.
 *
 * Tests should run each case inside a transaction and rollback in
 * afterEach so they don't pollute the shared dev DB.
 */
export async function bootDbTestModule(providers: any[] = []): Promise<{
  module: TestingModule;
  dataSource: DataSource;
}> {
  const module = await Test.createTestingModule({
    imports: [
      TypeOrmModule.forRoot({
        type: 'postgres',
        url: process.env.DATABASE_URL,
        entities: Object.values(entities),
        synchronize: false,
        logging: false,
      }),
    ],
    providers,
  }).compile();

  const dataSource = module.get(DataSource);
  return { module, dataSource };
}
```

- [ ] **Step 2: Add per-test transaction-isolation helper**

Append to `db-test-module.ts`:

```ts
/**
 * Wrap a test body in a SAVEPOINT and roll it back at the end.
 * Use this so tests share a single DataSource without polluting each
 * other's state. Caveat: code under test must not COMMIT explicitly.
 */
export async function withRolledBackTx<T>(
  ds: DataSource,
  body: (qr: import('typeorm').QueryRunner) => Promise<T>,
): Promise<T> {
  const qr = ds.createQueryRunner();
  await qr.connect();
  await qr.startTransaction();
  try {
    return await body(qr);
  } finally {
    await qr.rollbackTransaction();
    await qr.release();
  }
}
```

- [ ] **Step 3: Add seed helpers**

Create `test/integration/helpers/seed-helpers.ts`:

```ts
import { QueryRunner } from 'typeorm';

/** Insert a DM conversation between `login` and `other`, plus `unread` user messages from `other`. */
export async function seedDM(
  qr: QueryRunner,
  args: { login: string; other: string; convId: string; unread: number },
): Promise<void> {
  await qr.query(
    `INSERT INTO message_conversations (id, type, parent_conversation_id, created_at)
     VALUES ($1, 'dm', NULL, NOW())`,
    [args.convId],
  );
  await qr.query(
    `INSERT INTO message_conversation_participants (conversation_id, user_login)
     VALUES ($1, $2), ($1, $3)`,
    [args.convId, args.login, args.other],
  );
  for (let i = 0; i < args.unread; i++) {
    await qr.query(
      `INSERT INTO messages (id, conversation_id, sender_login, type, body, created_at)
       VALUES (gen_random_uuid(), $1, $2, 'user', $3, NOW())`,
      [args.convId, args.other, `dm-msg-${i}`],
    );
  }
}

export async function seedGroup(
  qr: QueryRunner,
  args: { login: string; groupId: string; unread: number; senderLogin: string },
): Promise<void> {
  await qr.query(
    `INSERT INTO message_conversations (id, type, parent_conversation_id, created_at)
     VALUES ($1, 'group', NULL, NOW())`,
    [args.groupId],
  );
  await qr.query(
    `INSERT INTO message_conversation_participants (conversation_id, user_login)
     VALUES ($1, $2), ($1, $3)`,
    [args.groupId, args.login, args.senderLogin],
  );
  for (let i = 0; i < args.unread; i++) {
    await qr.query(
      `INSERT INTO messages (id, conversation_id, sender_login, type, body, created_at)
       VALUES (gen_random_uuid(), $1, $2, 'user', $3, NOW())`,
      [args.groupId, args.senderLogin, `group-msg-${i}`],
    );
  }
}

export async function seedTeamWithTopics(
  qr: QueryRunner,
  args: {
    login: string;
    teamId: string;
    topics: Array<{ id: string; cursorAt: string | null }>;
    teamCursorAt: string | null;
    mainUnread: number;
    topicUnreads: Record<string, number>;
    senderLogin: string;
  },
): Promise<void> {
  await qr.query(
    `INSERT INTO message_conversations (id, type, parent_conversation_id, created_at)
     VALUES ($1, 'team', NULL, NOW())`,
    [args.teamId],
  );
  await qr.query(
    `INSERT INTO message_conversation_participants (conversation_id, user_login)
     VALUES ($1, $2), ($1, $3)`,
    [args.teamId, args.login, args.senderLogin],
  );
  for (const t of args.topics) {
    await qr.query(
      `INSERT INTO message_conversations (id, type, parent_conversation_id, created_at)
       VALUES ($1, 'topic', $2, NOW())`,
      [t.id, args.teamId],
    );
    if (t.cursorAt) {
      await qr.query(
        `INSERT INTO message_read_cursors (conversation_id, user_login, last_read_at)
         VALUES ($1, $2, $3)`,
        [t.id, args.login, t.cursorAt],
      );
    }
  }
  if (args.teamCursorAt) {
    await qr.query(
      `INSERT INTO message_read_cursors (conversation_id, user_login, last_read_at)
       VALUES ($1, $2, $3)`,
      [args.teamId, args.login, args.teamCursorAt],
    );
  }
  for (let i = 0; i < args.mainUnread; i++) {
    await qr.query(
      `INSERT INTO messages (id, conversation_id, sender_login, type, body, created_at)
       VALUES (gen_random_uuid(), $1, $2, 'user', $3, NOW())`,
      [args.teamId, args.senderLogin, `main-${i}`],
    );
  }
  for (const [topicId, count] of Object.entries(args.topicUnreads)) {
    for (let i = 0; i < count; i++) {
      await qr.query(
        `INSERT INTO messages (id, conversation_id, sender_login, type, body, created_at)
         VALUES (gen_random_uuid(), $1, $2, 'user', $3, NOW())`,
        [topicId, args.senderLogin, `topic-${topicId}-${i}`],
      );
    }
  }
}
```

Verify exact participant table/column names against schema before running. If `message_conversation_participants` is named differently in this codebase (e.g. `conversation_members`), adjust to match the entity at `src/database/postgres/entities/`.

- [ ] **Step 4: Add Jest config branch for integration specs**

Edit `test/jest-e2e.json`:

```json
{
  "testRegex": "(\\.integration-spec\\.ts$|\\.e2e-spec\\.ts$)",
  ...
}
```

(Or add a new `jest-integration.json` file and a `yarn test:integration` package script — pick whichever the team prefers. Defaulting to extending e2e config keeps it simple.)

- [ ] **Step 5: Add a smoke integration spec to prove the harness works**

Create `test/integration/modules/messages/get-conversations-topic-bubble.integration-spec.ts`:

```ts
import { DataSource } from 'typeorm';
import { bootDbTestModule, withRolledBackTx } from '../../helpers/db-test-module';
import { seedDM } from '../../helpers/seed-helpers';

describe('integration harness smoke', () => {
  let ds: DataSource;

  beforeAll(async () => {
    const { dataSource } = await bootDbTestModule();
    ds = dataSource;
  });

  afterAll(async () => {
    await ds.destroy();
  });

  it('connects to local Postgres and rolls back a seed', async () => {
    await withRolledBackTx(ds, async (qr) => {
      await seedDM(qr, {
        login: 'alice', other: 'bob',
        convId: '11111111-1111-1111-1111-111111111111',
        unread: 2,
      });
      const rows = await qr.query(
        `SELECT COUNT(*)::int AS cnt FROM messages WHERE conversation_id = $1`,
        ['11111111-1111-1111-1111-111111111111'],
      );
      expect(rows[0].cnt).toBe(2);
    });
    // After rollback, the conversation must not exist.
    const after = await ds.query(
      `SELECT COUNT(*)::int AS cnt FROM message_conversations WHERE id = $1`,
      ['11111111-1111-1111-1111-111111111111'],
    );
    expect(after[0].cnt).toBe(0);
  });
});
```

- [ ] **Step 6: Run smoke**

Ensure local Postgres is reachable with the credentials in `backend/.env`. Then:

```bash
cd ../gitchat-webapp/backend
yarn test:e2e get-conversations-topic-bubble.integration-spec.ts
```

Expected: PASS.

If the test cannot connect, the next steps are debugging the env (DATABASE_URL, port, password) — do not proceed to Task 1 until the smoke is green.

- [ ] **Step 7: Commit**

```bash
cd ../gitchat-webapp
git add backend/test/integration/helpers/db-test-module.ts \
        backend/test/integration/helpers/seed-helpers.ts \
        backend/test/integration/modules/messages/get-conversations-topic-bubble.integration-spec.ts \
        backend/test/jest-e2e.json
git commit -m "test(infra): real-Postgres integration spec scaffold"
```

---

### Task 1: Read-cursor helper + topic-ids preload (test-first)

> **For Tasks 1-5 of Track 1:** All tests live in `test/integration/modules/messages/get-conversations-topic-bubble.integration-spec.ts` (created in Task 0). Each `it()` body must be wrapped in `withRolledBackTx(ds, async (qr) => { ... })`. Helpers (`seedDM`, `seedGroup`, `seedTeamWithTopics`) come from `../../helpers/seed-helpers`. Replace any direct `dataSource.query(...)` in the test snippets below with `qr.query(...)` (the QueryRunner from the rollback wrapper). Call `service.getConversations({ login })` via the boot helper's compiled module — Task 1 Step 1 below shows the wiring.

**Files:**
- Modify: `../gitchat-webapp/backend/src/modules/messages/services/messages.service.ts:461-475`
- Test: `../gitchat-webapp/backend/test/integration/modules/messages/get-conversations-topic-bubble.integration-spec.ts` (extend from Task 0's smoke)

- [ ] **Step 1: Write the failing test — preload + cursor expansion**

Add to `messages.service.spec.ts`:

```ts
describe('getConversations — topic unread bubble', () => {
  it('preloads read cursors for child topics, not just convIds', async () => {
    const fixture = await seedTeamWithTopics({
      login: 'alice',
      teamId: 'team-1',
      topics: [
        { id: 'topic-a', cursorAt: '2026-05-15T10:00:00Z' },
        { id: 'topic-b', cursorAt: null }, // never opened
      ],
      teamCursorAt: '2026-05-15T09:00:00Z',
      // 2 main-thread msgs after cursor, 3 in topic-a after cursor,
      // 4 in topic-b (no cursor → all unread)
      mainUnread: 2,
      topicUnreads: { 'topic-a': 3, 'topic-b': 4 },
    });

    const result = await service.getConversations({ login: 'alice' });
    const team = result.data.find(c => c.id === 'team-1')!;
    expect(team.unreadCount).toBe(2 + 3 + 4); // = 9
  });
});
```

(The `seedTeamWithTopics` helper does not exist yet — Step 2 adds it.)

- [ ] **Step 2: Add test fixture helper**

Append to the test file's helpers section (near the existing `topicsAlreadyEnabled` helper around line 962):

```ts
async function seedTeamWithTopics(opts: {
  login: string;
  teamId: string;
  topics: Array<{ id: string; cursorAt: string | null }>;
  teamCursorAt: string | null;
  mainUnread: number;
  topicUnreads: Record<string, number>;
}): Promise<void> {
  // Insert a team conversation
  await dataSource.query(
    `INSERT INTO message_conversations (id, type, parent_conversation_id, created_at)
     VALUES ($1, 'team', NULL, NOW())`,
    [opts.teamId],
  );
  // Insert topics as child conversations
  for (const t of opts.topics) {
    await dataSource.query(
      `INSERT INTO message_conversations (id, type, parent_conversation_id, created_at)
       VALUES ($1, 'topic', $2, NOW())`,
      [t.id, opts.teamId],
    );
    if (t.cursorAt) {
      await dataSource.query(
        `INSERT INTO message_read_cursors (conversation_id, user_login, last_read_at)
         VALUES ($1, $2, $3)`,
        [t.id, opts.login, t.cursorAt],
      );
    }
  }
  // Team cursor
  if (opts.teamCursorAt) {
    await dataSource.query(
      `INSERT INTO message_read_cursors (conversation_id, user_login, last_read_at)
       VALUES ($1, $2, $3)`,
      [opts.teamId, opts.login, opts.teamCursorAt],
    );
  }
  // Main thread messages (after team cursor, from 'bob')
  for (let i = 0; i < opts.mainUnread; i++) {
    await dataSource.query(
      `INSERT INTO messages (id, conversation_id, sender_login, type, body, created_at)
       VALUES (gen_random_uuid(), $1, 'bob', 'user', $2, NOW())`,
      [opts.teamId, `main-${i}`],
    );
  }
  // Topic messages (from 'bob')
  for (const [topicId, count] of Object.entries(opts.topicUnreads)) {
    for (let i = 0; i < count; i++) {
      await dataSource.query(
        `INSERT INTO messages (id, conversation_id, sender_login, type, body, created_at)
         VALUES (gen_random_uuid(), $1, 'bob', 'user', $2, NOW())`,
        [topicId, `topic-${topicId}-${i}`],
      );
    }
  }
  // Membership for `login` on the team (so the conversation is visible)
  await ensureMembership(opts.login, opts.teamId);
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd ../gitchat-webapp/backend && yarn test:unit messages.service.spec.ts -t 'topic unread bubble'`
Expected: FAIL with `team.unreadCount === 2` (current behavior — only main thread counted).

- [ ] **Step 4: Implement preload + cursor expansion**

In `messages.service.ts`, between line 460 and the existing read-cursor block at line 466, insert:

```ts
// Topic ids whose parent is in convIds — needed so the unread aggregation
// can bubble topic messages up to their parent team row.
let topicIds: string[] = [];
if (convIds.length > 0) {
  const topicRows: { id: string }[] = await this.dataSource.query(
    `SELECT id FROM message_conversations
     WHERE parent_conversation_id = ANY($1)
       AND deleted_at IS NULL`,
    [convIds],
  );
  topicIds = topicRows.map(r => r.id);
}
const allConvIds = topicIds.length > 0 ? [...convIds, ...topicIds] : convIds;
```

Then change line 467-475 (the read-cursor fetch) to use `allConvIds`:

```ts
let readCursorMap = new Map<string, ReadCursorInfo>();
if (allConvIds.length > 0) {
  const readCursors = await this.messageReadCursorRepository.find({
    where: { conversationId: In(allConvIds), userLogin: login },
    select: ['conversationId', 'lastReadAt', 'lastReadMessageId'],
  });
  readCursorMap = new Map(readCursors.map(rc => [
    rc.conversationId,
    { lastReadAt: rc.lastReadAt, lastReadMessageId: rc.lastReadMessageId ?? null },
  ]));
}
```

And change `valuesPairs` construction at line 491-498 to iterate `allConvIds`:

```ts
const valuesPairs = allConvIds.map(id => {
  const cursorInfo = readCursorMap.get(id);
  const threshold = cursorInfo?.lastReadAt
    ? (cursorInfo.lastReadAt instanceof Date ? cursorInfo.lastReadAt.toISOString() : String(cursorInfo.lastReadAt))
    : epoch;
  return `('${id}'::uuid, '${threshold}'::timestamptz)`;
});
```

- [ ] **Step 5: Run test to verify it still fails the same way**

Run: `yarn test:unit messages.service.spec.ts -t 'topic unread bubble'`
Expected: still FAIL — the query hasn't changed yet, so the sum is still wrong (or now equal to `mainUnread` + 0 because topic ids are in `valuesPairs` but they group by `v.conv_id`, so their counts land under topic ids which don't appear in the response).

- [ ] **Step 6: Commit (preload only, query rewrite next task)**

```bash
cd ../gitchat-webapp
git add backend/src/modules/messages/services/messages.service.ts \
        backend/test/unit/modules/messages/messages.service.spec.ts
git commit -m "feat(messages): preload topic ids + cursors for parent unread rollup"
```

---

### Task 2: Rewrite 3a unread query — bubble to effective parent

**Files:**
- Modify: `../gitchat-webapp/backend/src/modules/messages/services/messages.service.ts:500-515`

- [ ] **Step 1: Rewrite the unread-count SQL**

Replace the existing query block at lines 502-515 with:

```ts
// 3a. Unread message counts — bubble topic rows up to parent team
const results: { effective_parent: string; cnt: number }[] = await this.dataSource.query(
  `SELECT COALESCE(c.parent_conversation_id, v.conv_id) AS effective_parent,
          COUNT(m.id)::int AS cnt
   FROM (VALUES ${valuesPairs.join(', ')}) AS v(conv_id, threshold)
   LEFT JOIN message_conversations c
     ON c.id = v.conv_id
     AND c.deleted_at IS NULL
   LEFT JOIN messages m
     ON m.conversation_id = v.conv_id
     AND m.sender_login != $1
     AND m.type = 'user'
     AND m.created_at > v.threshold
   GROUP BY COALESCE(c.parent_conversation_id, v.conv_id)`,
  [login],
);
for (const r of results) {
  unreadCountMap.set(r.effective_parent, r.cnt || 0);
}
```

- [ ] **Step 2: Run the test from Task 1 to verify it passes**

Run: `yarn test:unit messages.service.spec.ts -t 'topic unread bubble'`
Expected: PASS — `unreadCount === 9`.

- [ ] **Step 3: Add regression test for DM/group (no topics)**

Append to the same describe block:

```ts
it('regression — DM unread unchanged', async () => {
  await seedDM({ login: 'alice', other: 'bob', unread: 3 });
  const result = await service.getConversations({ login: 'alice' });
  const dm = result.data.find(c => c.id !== 'team-1' && !c.is_group)!;
  expect(dm.unreadCount).toBe(3);
});

it('regression — group without topics unchanged', async () => {
  await seedGroup({ login: 'alice', groupId: 'group-1', unread: 4 });
  const result = await service.getConversations({ login: 'alice' });
  const group = result.data.find(c => c.id === 'group-1')!;
  expect(group.unreadCount).toBe(4);
});

it('team — main thread only', async () => {
  await seedTeamWithTopics({
    login: 'alice', teamId: 'team-2',
    topics: [], teamCursorAt: '2026-05-15T00:00:00Z',
    mainUnread: 2, topicUnreads: {},
  });
  const result = await service.getConversations({ login: 'alice' });
  expect(result.data.find(c => c.id === 'team-2')!.unreadCount).toBe(2);
});

it('team — topics only (no main thread activity)', async () => {
  await seedTeamWithTopics({
    login: 'alice', teamId: 'team-3',
    topics: [
      { id: 't3-a', cursorAt: '2026-05-15T00:00:00Z' },
      { id: 't3-b', cursorAt: '2026-05-15T00:00:00Z' },
      { id: 't3-c', cursorAt: '2026-05-15T00:00:00Z' },
    ],
    teamCursorAt: null,
    mainUnread: 0,
    topicUnreads: { 't3-a': 3, 't3-b': 2, 't3-c': 1 },
  });
  const result = await service.getConversations({ login: 'alice' });
  expect(result.data.find(c => c.id === 'team-3')!.unreadCount).toBe(6);
});
```

(`seedDM` and `seedGroup` helpers exist in the test file already — see top of file.)

- [ ] **Step 4: Run all four tests**

Run: `yarn test:unit messages.service.spec.ts -t 'topic unread bubble'`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
cd ../gitchat-webapp
git add backend/src/modules/messages/services/messages.service.ts \
        backend/test/unit/modules/messages/messages.service.spec.ts
git commit -m "feat(messages): bubble topic unread to parent team row"
```

---

### Task 3: Rewrite 3b mentions query — same bubble pattern

**Files:**
- Modify: `../gitchat-webapp/backend/src/modules/messages/services/messages.service.ts:517-534`

- [ ] **Step 1: Write failing test for mention bubble**

```ts
it('team — @mention in topic bubbles to unreadMentionsCount', async () => {
  await seedTeamWithTopics({
    login: 'alice', teamId: 'team-m',
    topics: [{ id: 'tm-a', cursorAt: '2026-05-15T00:00:00Z' }],
    teamCursorAt: null,
    mainUnread: 0,
    topicUnreads: { 'tm-a': 0 },
  });
  // Insert one message in topic that mentions alice
  await dataSource.query(
    `INSERT INTO messages (id, conversation_id, sender_login, type, body, created_at)
     VALUES (gen_random_uuid(), 'tm-a', 'bob', 'user', 'hey @alice look', NOW())`,
  );
  const result = await service.getConversations({ login: 'alice' });
  const team = result.data.find(c => c.id === 'team-m')!;
  expect(team.unreadCount).toBe(1);
  expect(team.unreadMentionsCount).toBe(1);
});
```

- [ ] **Step 2: Run test, confirm failure**

Run: `yarn test:unit messages.service.spec.ts -t 'mention in topic bubbles'`
Expected: FAIL — `unreadMentionsCount === 0` because the mention query still keys by `v.conv_id`.

- [ ] **Step 3: Rewrite 3b query**

Replace lines 519-534 with:

```ts
const mentionPattern = `%@${login}%`;
const mentionResults: { effective_parent: string; cnt: number }[] = await this.dataSource.query(
  `SELECT COALESCE(c.parent_conversation_id, v.conv_id) AS effective_parent,
          COUNT(m.id)::int AS cnt
   FROM (VALUES ${valuesPairs.join(', ')}) AS v(conv_id, threshold)
   LEFT JOIN message_conversations c
     ON c.id = v.conv_id
     AND c.deleted_at IS NULL
   LEFT JOIN messages m
     ON m.conversation_id = v.conv_id
     AND m.sender_login != $1
     AND m.type = 'user'
     AND m.created_at > v.threshold
     AND m.deleted_at IS NULL
     AND m.body ILIKE $2
   GROUP BY COALESCE(c.parent_conversation_id, v.conv_id)`,
  [login, mentionPattern],
);
for (const r of mentionResults) {
  unreadMentionsMap.set(r.effective_parent, r.cnt || 0);
}
```

- [ ] **Step 4: Run test, confirm pass**

Run: `yarn test:unit messages.service.spec.ts -t 'mention in topic bubbles'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ../gitchat-webapp
git add backend/src/modules/messages/services/messages.service.ts \
        backend/test/unit/modules/messages/messages.service.spec.ts
git commit -m "feat(messages): bubble topic @mentions to parent team row"
```

---

### Task 4: Rewrite 3c reactions query — same bubble pattern

**Files:**
- Modify: `../gitchat-webapp/backend/src/modules/messages/services/messages.service.ts:537-552`

- [ ] **Step 1: Write failing test for reaction bubble**

```ts
it('team — reaction in topic bubbles to unreadReactionsCount', async () => {
  await seedTeamWithTopics({
    login: 'alice', teamId: 'team-r',
    topics: [{ id: 'tr-a', cursorAt: '2026-05-15T00:00:00Z' }],
    teamCursorAt: null,
    mainUnread: 0,
    topicUnreads: {},
  });
  // Alice posted a message in the topic; Bob reacted after Alice's cursor
  const msgRows = await dataSource.query(
    `INSERT INTO messages (id, conversation_id, sender_login, type, body, created_at)
     VALUES (gen_random_uuid(), 'tr-a', 'alice', 'user', 'mine', NOW() - INTERVAL '1 hour')
     RETURNING id`,
  );
  await dataSource.query(
    `INSERT INTO message_reactions (id, message_id, user_login, emoji, created_at)
     VALUES (gen_random_uuid(), $1, 'bob', '👍', NOW())`,
    [msgRows[0].id],
  );
  const result = await service.getConversations({ login: 'alice' });
  expect(result.data.find(c => c.id === 'team-r')!.unreadReactionsCount).toBe(1);
});
```

- [ ] **Step 2: Run test, confirm failure**

Run: `yarn test:unit messages.service.spec.ts -t 'reaction in topic bubbles'`
Expected: FAIL — `unreadReactionsCount === 0`.

- [ ] **Step 3: Rewrite 3c query**

Replace lines 537-552 with:

```ts
const reactionResults: { effective_parent: string; cnt: number }[] = await this.dataSource.query(
  `SELECT COALESCE(c.parent_conversation_id, v.conv_id) AS effective_parent,
          COUNT(DISTINCT r.id)::int AS cnt
   FROM (VALUES ${valuesPairs.join(', ')}) AS v(conv_id, threshold)
   LEFT JOIN message_conversations c
     ON c.id = v.conv_id
     AND c.deleted_at IS NULL
   JOIN messages m
     ON m.conversation_id = v.conv_id
     AND m.sender_login = $1
     AND m.type = 'user'
     AND m.deleted_at IS NULL
   JOIN message_reactions r
     ON r.message_id = m.id
     AND r.user_login != $1
     AND r.created_at > v.threshold
   GROUP BY COALESCE(c.parent_conversation_id, v.conv_id)`,
  [login],
);
for (const r of reactionResults) {
  unreadReactionsMap.set(r.effective_parent, r.cnt || 0);
}
```

- [ ] **Step 4: Run test, confirm pass**

Run: `yarn test:unit messages.service.spec.ts -t 'reaction in topic bubbles'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ../gitchat-webapp
git add backend/src/modules/messages/services/messages.service.ts \
        backend/test/unit/modules/messages/messages.service.spec.ts
git commit -m "feat(messages): bubble topic reactions to parent team row"
```

---

### Task 5: Edge-case tests — deleted topic, parent outside convIds

**Files:**
- Test: `../gitchat-webapp/backend/test/unit/modules/messages/messages.service.spec.ts`

- [ ] **Step 1: Add the three edge-case tests**

```ts
it('deleted topic does not contribute to parent unread', async () => {
  await seedTeamWithTopics({
    login: 'alice', teamId: 'team-d',
    topics: [{ id: 'td-a', cursorAt: null }],
    teamCursorAt: null,
    mainUnread: 0,
    topicUnreads: { 'td-a': 5 },
  });
  await dataSource.query(
    `UPDATE message_conversations SET deleted_at = NOW() WHERE id = 'td-a'`,
  );
  const result = await service.getConversations({ login: 'alice' });
  expect(result.data.find(c => c.id === 'team-d')!.unreadCount).toBe(0);
});

it('topic with no read cursor counts every message as unread', async () => {
  await seedTeamWithTopics({
    login: 'alice', teamId: 'team-n',
    topics: [{ id: 'tn-a', cursorAt: null }],
    teamCursorAt: null,
    mainUnread: 0,
    topicUnreads: { 'tn-a': 4 },
  });
  const result = await service.getConversations({ login: 'alice' });
  expect(result.data.find(c => c.id === 'team-n')!.unreadCount).toBe(4);
});

it('topic whose parent is not in convIds does not leak into response', async () => {
  // Build a topic under a team that alice is NOT a member of.
  await dataSource.query(
    `INSERT INTO message_conversations (id, type, parent_conversation_id, created_at)
     VALUES ('team-orphan', 'team', NULL, NOW())`,
  );
  await dataSource.query(
    `INSERT INTO message_conversations (id, type, parent_conversation_id, created_at)
     VALUES ('topic-orphan', 'topic', 'team-orphan', NOW())`,
  );
  await dataSource.query(
    `INSERT INTO messages (id, conversation_id, sender_login, type, body, created_at)
     VALUES (gen_random_uuid(), 'topic-orphan', 'bob', 'user', 'x', NOW())`,
  );
  const result = await service.getConversations({ login: 'alice' });
  expect(result.data.find(c => c.id === 'team-orphan')).toBeUndefined();
});
```

- [ ] **Step 2: Run all edge-case tests**

Run: `yarn test:unit messages.service.spec.ts -t 'topic unread bubble'`
Expected: all PASS.

- [ ] **Step 3: Run the full messages.service test suite (full regression)**

Run: `cd ../gitchat-webapp/backend && yarn test:unit messages.service.spec.ts`
Expected: all PASS (pre-existing DM/group/team tests unchanged).

- [ ] **Step 4: Commit**

```bash
cd ../gitchat-webapp
git add backend/test/unit/modules/messages/messages.service.spec.ts
git commit -m "test(messages): edge cases for topic unread bubble"
```

---

## Track 2: iOS

### Task 6: `TopicListStore` — ParentUnreadDelta type + publisher (test-first)

**Files:**
- Modify: `GitchatIOS/Features/Conversations/Topics/TopicListStore.swift`
- Create: `GitchatIOSTests/Conversations/TopicListStoreParentDeltaTests.swift`

- [ ] **Step 1: Write the failing test file**

Create `GitchatIOSTests/Conversations/TopicListStoreParentDeltaTests.swift`:

```swift
import XCTest
import Combine
@testable import Gitchat

@MainActor
final class TopicListStoreParentDeltaTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func test_bumpUnread_emitsParentDelta() {
        let store = TopicListStore(maxParents: 10, defaults: .ephemeral())
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 0),
        ], forParent: "team-1")

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        store.bumpUnread(topicId: "t1", parentId: "team-1", by: 1)

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.parentId, "team-1")
        XCTAssertEqual(observed.first?.delta, 1)
    }

    func test_clearUnread_emitsNegativeDeltaEqualToPriorCount() {
        let store = TopicListStore(maxParents: 10, defaults: .ephemeral())
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 4),
        ], forParent: "team-1")

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        store.clearUnread(topicId: "t1", parentId: "team-1")

        XCTAssertEqual(observed.first?.delta, -4,
            "Must emit the true delta (-4), not -Int.max — saturation is internal.")
    }

    func test_messageEvent_emitsDeltaOfOne_whenNotActiveSurface() {
        let store = TopicListStore(maxParents: 10, defaults: .ephemeral())
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 2),
        ], forParent: "team-1")
        store.setActiveSurface(nil) // user is NOT on this topic

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        let evt = TopicSocketEvent.message(
            parentId: "team-1",
            topicId: "t1",
            message: Message.fixture(content: "new", createdAt: "2099-01-01T00:00:00Z")
        )
        store.applyEvent(evt)

        XCTAssertEqual(observed.first?.delta, 1)
    }

    func test_messageEvent_emitsNothing_whenIsActiveSurface() {
        let store = TopicListStore(maxParents: 10, defaults: .ephemeral())
        store.setTopics([
            Topic.fixture(id: "t1", parentId: "team-1", unread: 2),
        ], forParent: "team-1")
        store.setActiveSurface("t1") // user IS on this topic

        var observed: [TopicListStore.ParentUnreadDelta] = []
        store.parentUnreadDeltas.sink { observed.append($0) }.store(in: &cancellables)

        let evt = TopicSocketEvent.message(
            parentId: "team-1",
            topicId: "t1",
            message: Message.fixture(content: "new", createdAt: "2099-01-01T00:00:00Z")
        )
        store.applyEvent(evt)

        XCTAssertTrue(observed.isEmpty, "Active surface must suppress both topic bump and parent delta.")
    }
}

private extension UserDefaults {
    static func ephemeral() -> UserDefaults {
        let d = UserDefaults(suiteName: "TopicListStoreParentDeltaTests-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: "TopicListStoreParentDeltaTests")
        return d
    }
}
```

(`Topic.fixture` and `Message.fixture` helpers are in `GitchatIOSTests/Helpers/Message+TestFixture.swift` and `Fixtures.swift` — if `Topic.fixture` doesn't exist yet, add it to `Fixtures.swift` mirroring the in-file `topic(id:name:...)` builder at `TopicRow.swift:155-178`.)

- [ ] **Step 2: Regenerate Xcode project and verify the new file is registered**

Run: `xcodegen generate && grep -c TopicListStoreParentDeltaTests GitchatIOS.xcodeproj/project.pbxproj`
Expected: ≥ 1.

- [ ] **Step 3: Run new tests, confirm they fail to compile**

Run:
```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GitchatIOSTests/TopicListStoreParentDeltaTests
```
Expected: compile error — `parentUnreadDeltas` and `TopicListStore.ParentUnreadDelta` don't exist.

- [ ] **Step 4: Add the type and publisher to `TopicListStore`**

In `TopicListStore.swift`, add at the top of the class (just after `@Published private(set) var activeSurfaceId: String?` around line 17):

```swift
/// Emitted by every successful topic-unread mutation. Subscribers
/// (e.g. `ConversationsViewModel`) apply the delta to the parent
/// team's `unreadCount` on the outer Chats list so the badge reflects
/// topic activity in real time. The delta is the *true* change in
/// the topic's `unread_count` after clamping — never `-Int.max`.
let parentUnreadDeltas = PassthroughSubject<ParentUnreadDelta, Never>()

struct ParentUnreadDelta: Equatable {
    let parentId: String
    let delta: Int
}
```

- [ ] **Step 5: Run tests, expect them to fail at runtime (helper not wired yet)**

Run the same test command.
Expected: tests now compile but FAIL — no deltas are emitted because the mutation paths don't publish yet.

- [ ] **Step 6: Commit (publisher scaffold only)**

```bash
git add GitchatIOS/Features/Conversations/Topics/TopicListStore.swift \
        GitchatIOSTests/Conversations/TopicListStoreParentDeltaTests.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "feat(topics): add ParentUnreadDelta publisher on TopicListStore"
```

---

### Task 7: Route all unread mutations through a single helper

**Files:**
- Modify: `GitchatIOS/Features/Conversations/Topics/TopicListStore.swift:121-209`

- [ ] **Step 1: Add the private helper**

Insert this method right before `bumpUnread` (around line 120):

```swift
/// Single emission point for topic-unread mutations. Computes the
/// true delta (`newClamped - old`) after applying the floor-at-zero
/// clamp, and publishes it to `parentUnreadDeltas`. All three callers
/// (`bumpUnread`, `clearUnread`, and the `.message` realtime path)
/// route through here so the outer Chats list parent row stays in
/// sync with topic-level changes.
private func setTopicUnread(
    topicId: String,
    parentId: String,
    transform: (Int) -> Int
) {
    guard var arr = topicsByParent[parentId],
          let idx = arr.firstIndex(where: { $0.id == topicId }) else { return }
    let old = arr[idx].unread_count
    let newClamped = max(0, transform(old))
    let delta = newClamped - old
    guard delta != 0 else { return }
    let t = arr[idx]
    arr[idx] = Topic(
        id: t.id, parent_conversation_id: t.parent_conversation_id,
        name: t.name, icon_emoji: t.icon_emoji, color_token: t.color_token,
        is_general: t.is_general, pin_order: t.pin_order, archived_at: t.archived_at,
        last_message_at: t.last_message_at, last_message_preview: t.last_message_preview,
        last_sender_login: t.last_sender_login, unread_count: newClamped,
        unread_mentions_count: t.unread_mentions_count,
        unread_reactions_count: t.unread_reactions_count,
        created_by: t.created_by, created_at: t.created_at
    )
    topicsByParent[parentId] = sort(arr, parentId: parentId)
    parentUnreadDeltas.send(ParentUnreadDelta(parentId: parentId, delta: delta))
}
```

- [ ] **Step 2: Rewrite `bumpUnread` to use the helper**

Replace lines 121-133 with:

```swift
func bumpUnread(topicId: String, parentId: String, by delta: Int) {
    setTopicUnread(topicId: topicId, parentId: parentId) { $0 + delta }
}

func clearUnread(topicId: String, parentId: String) {
    setTopicUnread(topicId: topicId, parentId: parentId) { _ in 0 }
}
```

(Note: `clearUnread` now passes `_ in 0` instead of routing through `bumpUnread(by: -.max)`. The behavior is identical at the topic level — both clamp to 0 — but this path emits the correct `-old` delta.)

- [ ] **Step 3: Rewrite the `.message` event handler's unread path**

In the `case .message` branch (around line 176), replace the inline `update(topicId:parentId:)` block's `newUnread` computation with a call through the helper. The whole branch becomes:

```swift
case .message(let parentId, let topicId, let message):
    let isActiveSurface = (topicId == activeSurfaceId)
    // Preview / timestamp / sender update first — no unread side effect.
    update(topicId: topicId, parentId: parentId) { t in
        if let curAt = t.last_message_at,
           let msgAt = message.created_at,
           msgAt < curAt {
            return
        }
        let preview = message.content.isEmpty ? t.last_message_preview : message.content
        t = Topic(
            id: t.id, parent_conversation_id: t.parent_conversation_id,
            name: t.name, icon_emoji: t.icon_emoji, color_token: t.color_token,
            is_general: t.is_general, pin_order: t.pin_order,
            archived_at: t.archived_at,
            last_message_at: message.created_at ?? t.last_message_at,
            last_message_preview: preview,
            last_sender_login: message.sender,
            unread_count: t.unread_count, // unchanged here
            unread_mentions_count: t.unread_mentions_count,
            unread_reactions_count: t.unread_reactions_count,
            created_by: t.created_by, created_at: t.created_at
        )
    }
    // Unread bump goes through the single emission helper.
    if !isActiveSurface {
        // Re-check monotonic guard: if the .update above bailed because
        // the message was older, we must not bump either.
        if let arr = topicsByParent[parentId],
           let t = arr.first(where: { $0.id == topicId }),
           t.last_message_at == message.created_at {
            setTopicUnread(topicId: topicId, parentId: parentId) { $0 + 1 }
        }
    }
```

- [ ] **Step 4: Run the new TopicListStore tests + the existing topic event tests**

Run:
```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GitchatIOSTests/TopicListStoreParentDeltaTests \
  -only-testing:GitchatIOSTests/TopicSocketEventTests
```
Expected: all PASS — the four new tests now emit deltas through the helper, and the existing socket-event tests still pass because topic-level behavior is unchanged.

- [ ] **Step 5: Commit**

```bash
git add GitchatIOS/Features/Conversations/Topics/TopicListStore.swift
git commit -m "refactor(topics): route unread mutations through single emission helper"
```

---

### Task 8: `ConversationsViewModel` subscriber — apply parent delta

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift:1-50` (ConversationsViewModel)
- Modify: `GitchatIOSTests/Conversations/ConversationsViewModelTopicRealtimeTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `ConversationsViewModelTopicRealtimeTests.swift`:

```swift
func test_applyParentUnreadDelta_bumpsRowUnread() {
    let vm = ConversationsViewModel()
    vm.conversations = [makeTeam(id: "team-1", unreadCount: 2)]

    vm.applyParentUnreadDelta(parentId: "team-1", delta: 3)

    XCTAssertEqual(vm.conversations.first?.unreadCount, 5)
}

func test_applyParentUnreadDelta_clampsAtZero() {
    let vm = ConversationsViewModel()
    vm.conversations = [makeTeam(id: "team-1", unreadCount: 1)]

    vm.applyParentUnreadDelta(parentId: "team-1", delta: -10)

    XCTAssertEqual(vm.conversations.first?.unreadCount, 0)
}

func test_applyParentUnreadDelta_ignoresUnknownParent() {
    let vm = ConversationsViewModel()
    vm.conversations = [makeTeam(id: "team-1", unreadCount: 2)]

    vm.applyParentUnreadDelta(parentId: "team-stranger", delta: 5)

    XCTAssertEqual(vm.conversations.first?.unreadCount, 2,
        "Unknown parent must be a no-op, not a crash.")
}
```

(`makeTeam(id:unreadCount:)` may need an overload — extend the existing helper at the bottom of this test file to accept `unreadCount: Int = 0`.)

- [ ] **Step 2: Run tests, confirm they fail to compile**

Run:
```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GitchatIOSTests/ConversationsViewModelTopicRealtimeTests
```
Expected: compile error — `applyParentUnreadDelta` doesn't exist.

- [ ] **Step 3: Add `applyParentUnreadDelta` to `ConversationsViewModel`**

In `ConversationsListView.swift`, inside `ConversationsViewModel` (right after `applyIncomingTopicMessage` if it exists, or right after `applyIncomingMessage`):

```swift
/// Apply a topic-derived unread delta to the parent team row on the
/// outer Chats list. Source: `TopicListStore.parentUnreadDeltas`.
/// No-op when the parent isn't currently in `conversations`
/// (archived, paginated out, etc).
func applyParentUnreadDelta(parentId: String, delta: Int) {
    guard let idx = conversations.firstIndex(where: { $0.id == parentId }) else { return }
    let c = conversations[idx]
    let newUnread = max(0, c.unreadCount + delta)
    conversations[idx] = c.withUnreadCount(newUnread)
}
```

Add the builder to `Models.swift` (next to the existing `withLastMessage` and `withLatestMessageFrom` builders, around line 97-182):

```swift
func withUnreadCount(_ newValue: Int) -> Conversation {
    Conversation(
        id: id,
        type: type,
        is_group: is_group,
        group_name: group_name,
        group_avatar_url: group_avatar_url,
        repo_full_name: repo_full_name,
        participants: participants,
        other_user: other_user,
        last_message: last_message,
        last_message_preview: last_message_preview,
        last_message_text: last_message_text,
        last_message_at: last_message_at,
        unread_count: newValue,
        pinned: pinned,
        pinned_at: pinned_at,
        is_request: is_request,
        updated_at: updated_at,
        is_muted: is_muted,
        has_mention: has_mention,
        has_reaction: has_reaction,
        topics_enabled: topics_enabled,
        has_topics: has_topics,
        topic_chips: topic_chips
    )
}
```

- [ ] **Step 4: Wire the subscription**

Add this stored property to `ConversationsViewModel` (under the existing `@Published` declarations, near `private var loadTask: Task<Void, Never>?` at line 17):

```swift
private var parentUnreadCancellable: AnyCancellable?
```

Extend the existing `init()` at line 182 from:

```swift
init() {
    if let cached = ConversationsCache.shared.get() {
        self.conversations = cached
    }
}
```

to:

```swift
init(topicStore: TopicListStore = .shared) {
    if let cached = ConversationsCache.shared.get() {
        self.conversations = cached
    }
    parentUnreadCancellable = topicStore.parentUnreadDeltas
        .receive(on: DispatchQueue.main)
        .sink { [weak self] event in
            self?.applyParentUnreadDelta(parentId: event.parentId, delta: event.delta)
        }
}
```

The default argument keeps all existing `ConversationsViewModel()` call sites valid; tests inject a fresh store via `ConversationsViewModel(topicStore: store)`.

Make sure `Combine` is imported at the top of the file:

```swift
import Combine
```

- [ ] **Step 5: Run tests, confirm pass**

Run:
```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GitchatIOSTests/ConversationsViewModelTopicRealtimeTests
```
Expected: all PASS, including the three new ones.

- [ ] **Step 6: End-to-end test through the publisher**

Add one more test that exercises the full pipeline (TopicListStore → publisher → ConversationsViewModel):

```swift
func test_topicStoreBump_flowsThroughPublisherToParentRow() async {
    let store = TopicListStore(maxParents: 10, defaults: .ephemeral())
    store.setTopics([
        Topic.fixture(id: "t1", parentId: "team-1", unread: 0),
    ], forParent: "team-1")
    let vm = ConversationsViewModel(topicStore: store)
    vm.conversations = [makeTeam(id: "team-1", unreadCount: 0)]

    store.bumpUnread(topicId: "t1", parentId: "team-1", by: 2)
    // Let the .receive(on: main) hop drain.
    await Task.yield()

    XCTAssertEqual(vm.conversations.first?.unreadCount, 2)
}
```

Run the test, expect PASS.

- [ ] **Step 7: Commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift \
        GitchatIOS/Core/Models/Models.swift \
        GitchatIOSTests/Conversations/ConversationsViewModelTopicRealtimeTests.swift
git commit -m "feat(conversations): apply topic unread deltas to parent team row"
```

---

### Task 9: Row-rendering smoke test for the badge

**Files:**
- Create: `GitchatIOSTests/Conversations/ConversationsListRowUnreadBadgeTests.swift`

- [ ] **Step 1: Drop `private` on the accessibility label property**

In `ConversationsListView.swift:1327`, change:

```swift
private var accessibilityRowLabel: String {
```

to:

```swift
var accessibilityRowLabel: String {
```

(Internal default; tests can read it via `@testable import Gitchat`.)

- [ ] **Step 2: Add `Conversation.fixtureTeam` to test helpers**

In `GitchatIOSTests/Helpers/Fixtures.swift`, add:

```swift
extension Conversation {
    static func fixtureTeam(id: String, unreadCount: Int = 0) -> Conversation {
        Conversation(
            id: id, type: "team", is_group: true,
            group_name: "Team \(id)", group_avatar_url: nil,
            repo_full_name: nil, participants: [], other_user: nil,
            last_message: nil, last_message_preview: nil,
            last_message_text: nil, last_message_at: nil,
            unread_count: unreadCount, pinned: nil, pinned_at: nil,
            is_request: nil, updated_at: nil, is_muted: nil,
            has_mention: nil, has_reaction: nil,
            topics_enabled: true, has_topics: true, topic_chips: nil
        )
    }
}
```

(Mirror the existing `Conversation` initializer in `Models.swift:111`. If a different fixture builder already exists, add an overload that takes `unreadCount`.)

- [ ] **Step 3: Write the test file**

Create `GitchatIOSTests/Conversations/ConversationsListRowUnreadBadgeTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Gitchat

@MainActor
final class ConversationsListRowUnreadBadgeTests: XCTestCase {

    func test_rowAccessibilityLabel_includesUnreadCount() {
        let team = Conversation.fixtureTeam(id: "team-1", unreadCount: 5)
        let row = ConversationRow(conversation: team, isLocallyRead: false)
        XCTAssertTrue(
            row.accessibilityRowLabel.contains("5 unread messages"),
            "Row a11y label must include '5 unread messages' when unreadCount = 5"
        )
    }

    func test_rowAccessibilityLabel_singularForOne() {
        let team = Conversation.fixtureTeam(id: "team-1", unreadCount: 1)
        let row = ConversationRow(conversation: team, isLocallyRead: false)
        XCTAssertTrue(row.accessibilityRowLabel.contains("1 unread message"))
        XCTAssertFalse(row.accessibilityRowLabel.contains("1 unread messages"))
    }

    func test_locallyRead_suppressesBadgeInLabel() {
        let team = Conversation.fixtureTeam(id: "team-1", unreadCount: 5)
        let row = ConversationRow(conversation: team, isLocallyRead: true)
        XCTAssertFalse(row.accessibilityRowLabel.contains("unread"))
    }
}
```

(If the `ConversationRow` initializer requires additional non-default parameters, fill them in with sensible defaults — its signature is at `ConversationsListView.swift:1083`. The three params used here — `conversation`, `isLocallyRead` — match the public surface; check the file for the rest.)

- [ ] **Step 2: Regenerate project and verify file is registered**

Run: `xcodegen generate && grep -c ConversationsListRowUnreadBadgeTests GitchatIOS.xcodeproj/project.pbxproj`
Expected: ≥ 1.

- [ ] **Step 3: Run the test**

Run:
```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GitchatIOSTests/ConversationsListRowUnreadBadgeTests
```
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add GitchatIOSTests/Conversations/ConversationsListRowUnreadBadgeTests.swift \
        GitchatIOSTests/Helpers/Fixtures.swift \
        GitchatIOS/Features/Conversations/ConversationsListView.swift \
        GitchatIOS.xcodeproj/project.pbxproj
git commit -m "test(conversations): row accessibility includes topic-bubbled unread"
```

---

## Track 3: Cross-repo verification

### Task 10: Full test sweep + manual two-simulator smoke

**Files:** none (verification only)

- [ ] **Step 1: Backend — full unit + integration**

Run: `cd ../gitchat-webapp/backend && yarn test:unit && yarn test:e2e`
Expected: all PASS, no regressions in pre-existing tests.

- [ ] **Step 2: iOS — full XCTest suite**

Run:
```bash
xcodebuild test -project GitchatIOS.xcodeproj -scheme GitchatIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GitchatIOSTests
```
Expected: all PASS.

- [ ] **Step 3: Deploy BE to dev and run two-sim manual smoke**

Bring up local backend pointing at the BE branch with all five backend tasks merged. Use `GitchatIOS local` scheme (`SIMCTL_CHILD_API_BASE_URL=http://localhost:3000/api/v1`).

Boot two simulators (iPhone 17 + iPhone 17 Pro):

```bash
xcrun simctl boot "iPhone 17"
xcrun simctl boot "iPhone 17 Pro"
```

Sign in as Alice on Sim A, Bob on Sim B. Both join Team T with topic `Bug Report`.

1. Sim B sits on Chats list. Sim A sends a message into `Bug Report`. **Expect:** Sim B's Team T row gains a badge `1` within ~1s; topic chip updates to the new message body.
2. Sim B opens the topic. **Expect:** badge disappears (clearUnread → delta -1).
3. Sim B backs out to Chats list. Sim A sends 3 more messages to `Bug Report` and 2 to main thread. **Expect:** Team T badge = 5.
4. Sim B opens Team T's main thread (not the topic). **Expect:** badge becomes 3 (main read, topic still unread).
5. Sim B kill-relaunches the app. **Expect:** badge = 3 (BE refetch confirms).

- [ ] **Step 4: Document smoke results**

Append a short results block to the PR description for each repo's PR (numbers, screenshots, any deviations).

- [ ] **Step 5: Open PRs**

For each repo independently:

```bash
# Backend
cd ../gitchat-webapp
git push -u origin <branch>
gh pr create --title "feat(messages): bubble topic unread to parent team row" \
             --body "<spec link + smoke results>"

# iOS
cd <root>/gitchat-ios-native
git push -u origin <branch>
gh pr create --title "feat(conversations): show topic-aware unread badge on team rows" \
             --body "<spec link + smoke results>"
```

**Important:** Per user preference, do NOT push or open PRs without an explicit "yes" from the user for each repo at the time of pushing.

---

## Rollout order

1. Land + deploy BE PR to dev. Soak ≥ 24h. Watch error logs for any conversation-list query slowdowns.
2. Once BE is on prod, land iOS PR (TestFlight build).
3. After ≥ 1 week TestFlight soak, submit to App Store.

iOS can technically land before BE without breaking — the new realtime bump path is internal — but the user-visible feature only works end-to-end once BE is deployed, so coordinate the order for QA clarity.
