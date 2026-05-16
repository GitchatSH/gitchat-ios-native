# Team row unread badge — bubble topic unread to parent team

**Status:** Pending user review
**Author:** Ethan
**Date:** 2026-05-16
**Scope:** Backend (`gitchat-webapp/backend`) + iOS (`gitchat-ios-native`). No extension / webapp UI changes — they inherit the BE fix automatically.

## Problem

A team (topics-enabled group) in the outer Chats list does not show an unread badge when its activity is in topics only. The screenshot the user flagged shows `gitchat_extension Team` with topic chip `🐛 Bug Report · …`, no numeric badge, even though the topic has 1 unread message.

Root cause is in `MessagesService.getConversations` (`gitchat-webapp/backend/src/modules/messages/services/messages.service.ts:502-512`). The unread SQL joins messages on `m.conversation_id = team_id`, but topic messages live in the `messages` table with `m.conversation_id = topic_id` (where the topic is a `message_conversations` row with `parent_conversation_id = team_id`). The query never reaches topic messages, so the team's `unreadCount` is always zero unless someone posts in the team's main thread.

The same blind spot applies to `unread_mentions_count` and `unread_reactions_count` for topic messages.

DMs and non-topics groups are unaffected — their `parent_conversation_id IS NULL`, so the new logic falls back to current behavior.

## Goal

Outer Chats list team row shows `unreadCount = (main thread unread) + (sum of every topic's unread)` so it behaves identically to DM/group rows. `unreadMentionsCount` / `unreadReactionsCount` bubble the same way.

## Non-goals

- Changing the per-topic badge inside the team's topic list (already correct via `TopicListStore`).
- Adding a new client-facing field. Existing `unreadCount` / `unreadMentionsCount` / `unreadReactionsCount` semantics widen to "team-wide" — backward-compatible at the wire format level.
- Webapp/extension UI work. The wire format stays the same; both surfaces inherit the fix.

## Backend change

### Type matrix (regression guard)

| Conversation type | `parent_conversation_id` | `effective_parent` | Behavior |
|---|---|---|---|
| DM | NULL | self | Unchanged |
| Group (no topics) | NULL | self | Unchanged |
| Team / community (with topics) | NULL | self | Main-thread unread + sum of topic unread |
| Topic (child) | team_id | team_id | New — folds into parent, never reported as standalone in conversation list response |

`parent_conversation_id` (not the `type` string) is the structural discriminator. A row only bubbles when `parent IS NOT NULL`; DMs/groups can never be affected because `COALESCE(parent, self) = self`.

### Algorithm

In `MessagesService.getConversations`, between read-cursor preload (line 463-475) and the unread/mentions/reactions queries (line 500-552):

1. **Expand the conversation set.** Query topic ids whose parent is in `convIds`:

   ```sql
   SELECT id, parent_conversation_id
   FROM message_conversations
   WHERE parent_conversation_id = ANY($1)
     AND deleted_at IS NULL
   ```

   Let `topicIds` = result ids. The expanded set is `convIds ∪ topicIds`.

2. **Extend the read-cursor fetch (line 467-475)** to cover the expanded set, so each topic has its own threshold.

3. **Rebuild `valuesPairs` (line 491-498)** from the expanded set — every member (team or topic) contributes its own `(id, threshold)` row.

4. **Rewrite the three SQL queries (3a/3b/3c)** to group by effective parent instead of `v.conv_id`:

   ```sql
   SELECT COALESCE(c.parent_conversation_id, v.conv_id) AS effective_parent,
          COUNT(m.id)::int AS cnt
   FROM (VALUES ...) AS v(conv_id, threshold)
   LEFT JOIN message_conversations c
     ON c.id = v.conv_id
     AND c.deleted_at IS NULL
   LEFT JOIN messages m
     ON m.conversation_id = v.conv_id
     AND m.sender_login != $1
     AND m.type = 'user'
     AND m.created_at > v.threshold
   GROUP BY COALESCE(c.parent_conversation_id, v.conv_id)
   ```

   Same shape for mentions (adds `m.body ILIKE '%@${login}%'`) and reactions (joins `message_reactions`).

5. **Map results back to `unreadCountMap` / `unreadMentionsMap` / `unreadReactionsMap`** keyed by the original `convIds` — entries keyed by `effective_parent`. Topic ids never appear as keys (they always COALESCE to their parent). Topics whose parent is outside `convIds` silently drop, which is correct (the parent isn't visible to this user in this listing).

### Edge cases

- **Topic archived** (`archived_at NOT NULL`): excluded by the JOIN predicate. `message_conversations` extends `AbstractEntityWithoutSoftDelete` (no `deleted_at` column); the archive bit is the canonical "inactive" flag here, matching the topic-chips embed query at `messages.service.ts:726`. Archived topic messages do not contribute.
- **No read cursor for a topic** (e.g. topic just created and user has never opened it): `threshold = epoch`, every topic message is unread. This mirrors current behavior for fresh DMs/groups.
- **Muted topic**: unread still counts toward team total. The mute affects notifications and visual treatment elsewhere; semantics here stay Telegram-style.
- **`is_general` topic**: no special-case. Treated as any topic.
- **Mention `%@${login}%`**: applies to topic bodies and bubbles up via the same COALESCE.
- **Reaction by self in topic** or **message authored by self**: existing `sender_login != $1` filters carry over unchanged.
- **Conversation metadata missing** (defensive): `LEFT JOIN message_conversations c` with no match → COALESCE falls back to `v.conv_id` (self). Behavior identical to today.

### Performance

- One extra preload query, bounded by `idx_mc_parent_id` (partial index on rows where parent is not null — already exists, see `message-conversation.entity.ts:58`).
- Each of the three unread queries grows by one `LEFT JOIN` on `message_conversations` (PK lookup) and a slightly larger `VALUES` list (teams + their topics). Topics per team are typically small (<50). Net cost is negligible.

## iOS change — realtime bump

After the BE fix, fresh `GET /conversations` responses are correct. The remaining gap is **realtime**: while the user sits on the Chats list and a new topic message arrives via WebSocket, the team row's `conversation.unreadCount` will not update until the next refresh.

The fix lives in `TopicListStore` and `ConversationsViewModel`. `TopicListStore` is already the single source of truth for topic-level bumps (`TopicListStore.swift:181`); we extend it to publish a derived "parent delta" on every effective topic-unread change.

### Wiring

1. **`TopicListStore` — single emission point.** Today, topic-unread mutations happen in two places: the public `bumpUnread(topicId:parentId:by:)` method (line 121) and the realtime-arrival branch that constructs a new `Topic` inline (around line 195). Route both through a single internal helper that computes `effectiveDelta = newUnread - oldUnread` after applying clamping and the `isActiveSurface` guard. Whenever `effectiveDelta != 0`, publish `ParentUnreadDelta(parentId, effectiveDelta)` on a `PassthroughSubject<ParentUnreadDelta, Never>` exposed by the store.
2. **`clearUnread`** uses the same helper — its emitted delta is `-previousTopicUnread`, not `-Int.max` (the saturation is internal to the topic mutation; the published delta must be the true change).
3. **`ConversationsViewModel`** — subscribes during init. On each event, locates the conversation row with `id == parentId` and applies `unreadCount = max(0, unreadCount + delta)`. No-op if the parent isn't in the current list (e.g. archived, paginated out).
4. **Active surface guard** — `TopicListStore` already skips the topic bump when `isActiveSurface == true`; because the parent delta is derived from `newUnread - oldUnread`, it's automatically zero in that case and nothing is published.

### Edge cases

- **User opens the team's main thread**: mark-read API hits the team's `conversation_id` only. Backend's recomputed `unreadCount` on the next refresh equals `0 (main) + sum(topics still unread)`. Realtime path is not involved.
- **User opens a topic**: `clearUnread` fires → parent row decrements by that topic's previous unread. The next BE refresh confirms.
- **Multiple new topic messages in flight**: each event bumps the parent by 1; final BE refresh authoritative.
- **Topic created mid-session**: arrives via WebSocket as part of the topic list; first message into it lands through the same bump path.

## Wire format

No change. `unreadCount`, `unreadMentionsCount`, `unreadReactionsCount` remain integers on the conversation DTO. Their semantics widen from "main thread of this conversation" to "this conversation + all its child topics" — but for non-topic conversations the value is identical to today.

## Test plan

### Backend (`gitchat-webapp/backend`)

Add to `MessagesService` test suite (unit + integration where applicable):

- **Regression — DM only**: user with two DMs, three unread each. `unreadCount === 3` for both. Snapshot byte-equal to pre-change baseline.
- **Regression — group without topics**: user with a single group, four unread. `unreadCount === 4`. Snapshot byte-equal.
- **Team, main thread only**: 2 unread in main, 0 topics. `unreadCount === 2`.
- **Team, topics only**: 0 in main, 3 + 2 + 1 across three topics. `unreadCount === 6`.
- **Team, mixed**: 2 in main + 3 + 2 + 1 in topics. `unreadCount === 8`.
- **Deleted topic excluded**: topic with `deleted_at = NOW()` and 5 unread → not counted.
- **No cursor for topic**: user without `message_read_cursors` row for a fresh topic with 4 messages → topic contributes 4.
- **Mention bubble**: `@${login}` in a topic message → `unreadMentionsCount` on team is 1.
- **Reaction bubble**: another user reacts to user's message in a topic → `unreadReactionsCount` on team is 1.
- **Topic with parent outside `convIds`** (manually constructed): does not leak into the response.

### iOS (`gitchat-ios-native`)

Extend `ConversationsViewModelTopicRealtimeTests`:

- `bumpUnread(topicId, parentId, by: 1)` → conversation row with `id == parentId` sees `unreadCount += 1`.
- `bumpUnread(topicId, parentId, by: 1)` with topic `isActiveSurface == true` → no bump on either topic or parent.
- `clearUnread(topicId, parentId)` after topic had 4 unread → parent decrements by 4.
- Parent not in list → no-op, no crash.

New test target: `ConversationsListRowUnreadBadgeTests` — render `ConversationRow` with `unreadCount = 5` and assert the badge view appears with accessibility label `"5 unread messages"` (the helper at `ConversationsListView.swift:1355`).

### Manual smoke (post-merge, two simulators)

1. Sim A sends to a topic on Team T. Sim B sits on Chats list → team row badge appears within ~1s; topic chip also updates.
2. Sim B opens that topic → badge decrements by exactly that topic's count.
3. Sim B opens Team T's main thread (not the topic) → topic-derived badge persists; main-thread bump consumes only its own unread.
4. Sim B kills app, relaunches → list refetch confirms badge matches manual sum.

## Rollout

- BE change is backward-compatible (wire format unchanged). Ship to dev → soak → prod.
- iOS realtime change is gated only on BE being deployed (the bump logic is internal; nothing breaks if BE still returns the old narrow `unreadCount`). Can land independently in TestFlight.
- No feature flag. The semantic widening is the desired behavior end-state.
