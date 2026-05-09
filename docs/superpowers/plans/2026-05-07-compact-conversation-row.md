# Compact ConversationRow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "clip regularBody to 60pt" workaround with a real `compactBody` that renders only the avatar + active halo + unread badge, fixing the ragged-text artifact while preserving tap targets.

**Architecture:** Add a new `compactBody` private view inside `ConversationRow`. The existing `body` switches between `regularBody` and `compactBody` based on the existing `compact: Bool` flag. Update the call-site in `conversationListRow(_:)` to drop `.clipped()`, switch alignment to `.center` in compact mode, and let `contentShape(Rectangle())` cover the full 60pt cell — this is the fix for the previous tap-target regression.

**Tech Stack:** SwiftUI, Mac Catalyst (iOS 16+). No test framework — verification is `xcodebuild` compile + manual visual run on a Catalyst simulator (per `CLAUDE.md`).

**Spec:** `docs/superpowers/specs/2026-05-07-compact-conversation-row-design.md`

**File touched (one):**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift`
  - `ConversationRow.body` (line 1160-1162) — switch on `compact`
  - Add `compactBody`, `haloOverlay`, `compactBadge` private vars inside `ConversationRow`
  - `conversationListRow(_:)` (line 524-540) — drop `.clipped()`, alignment `.center` when compact

---

### Task 1: Add `compactBody` and switch `body` on `compact` flag

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift:1160-1162`
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift` — insert new private vars right after `regularBody` ends (around line 1245)

- [ ] **Step 1: Switch `body` to dispatch on `compact`**

Find lines 1160-1162:

```swift
    var body: some View {
        regularBody
    }
```

Replace with:

```swift
    var body: some View {
        if compact {
            compactBody
        } else {
            regularBody
        }
    }
```

- [ ] **Step 2: Add `compactBody`, `haloOverlay`, `compactBadge` after `regularBody` closes**

Locate the end of `regularBody` (currently around line 1245, just before the `@ViewBuilder private var checkmarkView` declaration). Insert these three views immediately after the closing brace of `regularBody`:

```swift
    /// Avatar-only row used when the chats sidebar is narrowed to 60pt
    /// in topic mode. Renders the same avatar as `regularBody` (so visual
    /// identity carries over) plus an accent halo for the active row and
    /// a Telegram-style unread badge anchored to bottom-right.
    private var compactBody: some View {
        avatarOnly
            .overlay { if isActive { haloOverlay } }
            .overlay(alignment: .bottomTrailing) {
                if displayedUnread > 0 { compactBadge }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityRowLabel)
    }

    @ViewBuilder
    private var avatarOnly: some View {
        if conversation.isGroup {
            GroupAvatarView(
                name: conversation.group_name ?? conversation.displayTitle,
                avatarURL: conversation.group_avatar_url,
                groupId: conversation.id,
                size: avatarSize
            )
        } else {
            AvatarView(
                url: conversation.displayAvatarURL,
                size: avatarSize,
                login: conversation.other_user?.login
            )
        }
    }

    private var haloOverlay: some View {
        Circle()
            .stroke(Color("AccentColor"), lineWidth: 2)
            .padding(-3)
    }

    @ViewBuilder
    private var compactBadge: some View {
        let bg: Color = isMuted ? Color(.systemGray) : Color("AccentColor")
        Text(displayedUnread > 99 ? "99+" : "\(displayedUnread)")
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(bg, in: .capsule)
            .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 2))
            .offset(x: 4, y: 4)
    }
```

Notes for the engineer:
- `avatarOnly` is extracted because `regularBody` uses the same avatar block — keeping a single source matters if avatar code changes later.
- `haloOverlay` uses `padding(-3)` so the stroke sits ~3pt outside the avatar's circle edge. Same accent color as the active-row background in `regularBody`.
- `compactBadge` matches the unread-count pill in `rightIndicators` (line 1298-1313): same colors, same `99+` cap, same `.capsule` shape. The 2pt `.systemBackground` stroke "punches" the badge out of the avatar visually.
- The `.frame(maxWidth: .infinity, maxHeight: .infinity)` is critical — it makes `compactBody`'s rendered frame fill whatever the call-site allots, so `contentShape(Rectangle())` matches the full cell. This is what fixes the previous tap-target regression.

- [ ] **Step 3: Save the file**

No commit yet — Task 2 is the matching call-site change and they belong in one commit.

---

### Task 2: Update call-site in `conversationListRow(_:)` — drop `.clipped()`, switch alignment

**Files:**
- Modify: `GitchatIOS/Features/Conversations/ConversationsListView.swift:524-540`

- [ ] **Step 1: Replace the row modifier chain**

Find the function `conversationListRow(_:)` starting at line 524. The current body (lines 525-540 approximately) looks like:

```swift
    @ViewBuilder
    private func conversationListRow(_ convo: Conversation) -> some View {
        ConversationRow(
            conversation: convo,
            isLocallyRead: vm.locallyRead.contains(convo.id),
            isMuted: vm.isLocallyMuted(convo),
            isActive: isActiveRow(convo),
            compact: compact
        )
        .transaction { $0.animation = nil }
        .frame(maxWidth: compact ? 60 : .infinity, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .background(tappedConvoId == convo.id ? Color(.tertiarySystemBackground) : Color.clear)
        .scaleEffect(squeezedConvoId == convo.id ? rowSqueezeFactor(for: convo) : 1)
        .animation(.easeOut(duration: 0.20), value: squeezedConvoId == convo.id)
```

Make these edits:

1. **Drop** `.clipped()` (line 535) — `compactBody` no longer overflows so clipping is unnecessary, and removing it eliminates one possible source of hit-test masking.
2. **Change alignment** in the `.frame(...)` call to `.center` when compact, `.leading` otherwise.

Resulting chain:

```swift
    @ViewBuilder
    private func conversationListRow(_ convo: Conversation) -> some View {
        ConversationRow(
            conversation: convo,
            isLocallyRead: vm.locallyRead.contains(convo.id),
            isMuted: vm.isLocallyMuted(convo),
            isActive: isActiveRow(convo),
            compact: compact
        )
        .transaction { $0.animation = nil }
        .frame(maxWidth: compact ? 60 : .infinity, alignment: compact ? .center : .leading)
        .contentShape(Rectangle())
        .background(tappedConvoId == convo.id ? Color(.tertiarySystemBackground) : Color.clear)
        .scaleEffect(squeezedConvoId == convo.id ? rowSqueezeFactor(for: convo) : 1)
        .animation(.easeOut(duration: 0.20), value: squeezedConvoId == convo.id)
```

The rest of the function (the `.onTapGesture`, `.contextMenu`, etc. that follow) stays untouched.

- [ ] **Step 2: Save the file**

No commit yet — wait for build + manual verify.

---

### Task 3: Regenerate Xcode project + build

**Files:** none modified. Regenerate `project.pbxproj` even though no files were added — `xcodegen` is idempotent and this guards against any stale state.

- [ ] **Step 1: Run xcodegen**

Run from repo root:

```bash
xcodegen generate
```

Expected: `Created project at /Volumes/NNTH-DATA/Workspace/Works/gitchat-ios-native/GitchatIOS.xcodeproj`

- [ ] **Step 2: Build for Mac Catalyst**

Run:

```bash
xcodebuild -scheme Gitchat -destination 'platform=macOS,variant=Mac Catalyst' -configuration Debug build 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **` at the end. No Swift compiler errors.

If you get `error: cannot find 'compactBody' in scope` or similar — Task 1 didn't save, redo it.
If you get `error: extra argument 'alignment' in call` — the `.frame` modifier signature mismatch; verify the chain in Task 2 step 1.

---

### Task 4: Manual verify on Catalyst simulator

This is the substitute for unit tests (no XCTest target per `CLAUDE.md`). Run through each scenario explicitly — don't skip any.

- [ ] **Step 1: Boot Catalyst, open the app**

```bash
open -a "Simulator"
xcrun simctl list devices booted
```

If no Catalyst device booted, launch the app from Xcode (`⌘R`) with Mac Catalyst destination selected. Sign in if needed.

- [ ] **Step 2: Verify clean collapse**

In the app:
1. Find a chat with topics enabled (e.g., "Never Give Up" from the screenshot, or any group where the row shows a topic chip in its preview line).
2. Click it.

Expected:
- Sidebar narrows; chats column shows **only avatars centered in the column** — no clipped/sliced text bleeding over the right edge.
- The clicked chat's avatar shows an **orange halo** (Color("AccentColor") stroke).
- Topic list appears to the right of the avatar column.

If text is still visible past the avatar, Task 1 step 1's `body` switch didn't take. Re-check `ConversationRow.body`.

- [ ] **Step 3: Verify clicks still work**

Stream the app log in a separate terminal:

```bash
xcrun simctl spawn booted log stream --process Gitchat --level debug 2>&1 | grep -i "Topic\|openConversation"
```

In the app: while in topic mode, click a different avatar in the compact column.

Expected (in the log stream):
- `[Topic] openConversation id=<new convo id> hasTopics=...` fires.
- The right pane updates to show the new chat's topics (if it has topics) or its chat detail (if it's a DM — should also exit topic mode and expand the sidebar back).

If clicks miss, the tap-target fix didn't land. Re-check Task 2's modifier chain — the order matters: `.frame(...)` must come before `.contentShape(Rectangle())`.

- [ ] **Step 4: Verify unread badge**

Find a chat with unread messages (look for one with a count badge in the regular row). Enter topic mode by clicking a different topic-enabled chat — confirm the unread chat's avatar in the compact column has a small **orange capsule badge** at bottom-right with the count, ringed with a thin border that "punches it out" of the avatar.

Mute that chat (long-press / context-menu → Mute, or via `vm.toggleMute`). The badge should turn **gray**.

- [ ] **Step 5: Verify exit**

Click a DM (no topics) in the compact column. Expected: `router.exitTopicMode()` fires (visible in log stream), sidebar expands back to full width, all rows render `regularBody` (avatar + title + preview + timestamp).

---

### Task 5: Commit

- [ ] **Step 1: Stage and commit**

```bash
git add GitchatIOS/Features/Conversations/ConversationsListView.swift GitchatIOS.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
fix(ios): real compactBody for ConversationRow — no more clipped text

When entering topic mode, ConversationRow now switches to a dedicated
compactBody that renders only the avatar + active halo + unread badge,
instead of clipping regularBody to 60pt and leaving sliced text at the
column edge.

The previous compactBody attempt (cfb183b) was reverted because tap
targets broke. Fixed here by giving compactBody an explicit
maxWidth: .infinity frame so the rendered cell matches the 60pt outer
constraint exactly, letting contentShape(Rectangle()) cover the whole
cell.

Spec: docs/superpowers/specs/2026-05-07-compact-conversation-row-design.md
EOF
)"
```

- [ ] **Step 2: Verify commit landed**

```bash
git log -1 --stat
```

Expected: one commit on `hiru-topics-rework-entry`, two files changed
(`ConversationsListView.swift` and `project.pbxproj`).

---

## Self-review notes (already addressed)

- **Spec coverage:** all spec sections covered — body switch (Task 1), compactBody render (Task 1), call-site (Task 2), build verify (Task 3), each "Verification" scenario from the spec mapped to a manual step (Task 4), commit (Task 5).
- **Type/name consistency:** `compactBody`, `avatarOnly`, `haloOverlay`, `compactBadge` consistent across Task 1 references; `.frame(maxWidth: compact ? 60 : .infinity, alignment: compact ? .center : .leading)` matches between spec and Task 2.
- **No TDD steps:** intentional — repo has no XCTest target. Manual verify in Task 4 is the verification gate.
