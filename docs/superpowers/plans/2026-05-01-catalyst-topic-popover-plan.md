# Catalyst Topic Popover Implementation Plan

> ⚠️ **Superseded — pivoted 2026-05-01 to a Telegram-Desktop-style tabs strip.** The popover anchor (`ChatDetailTitleBar` in the SwiftUI toolbar) does not actually render on Catalyst (the navigation bar is force-hidden, custom header is iOS-only) — the popover entry point was undiscoverable in manual testing. The shipped implementation uses a horizontal tabs strip rendered via `.safeAreaInset(edge: .top)` on the chat detail. See the spec's §0 Pivot section for the new design and the contributor log entry for 2026-05-01 for the full diff. Tasks 1, 4, 5, 7, 8 below still apply (the `TopicListContent` / `TopicListSheet` split, xcodegen flow, build verification, contributor log update). Tasks 2 and 3 were replaced — the actually-shipped equivalents are: Task 2′ create `TopicTabsStrip.swift` (Catalyst-only); Task 3′ attach `.safeAreaInset(edge: .top) { TopicTabsStrip(...) }` on `ChatView` in `ChatDetailView.chatShell`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bottom-sheet topic list rendering on Mac Catalyst with a SwiftUI `.popover` anchored on the chat header, while keeping the iPhone/iPad sheet behavior identical.

**Architecture:** Split the current monolithic `TopicListSheet` into `TopicListContent` (cross-platform body) + `TopicListSheet` (iOS wrapper). Add a Catalyst-only `TopicListPopover` (`#if targetEnvironment(macCatalyst)` at the file top). In `ChatDetailView`, gate the existing root `.sheet` to non-Catalyst and attach a Catalyst-only `.popover` modifier to the toolbar `ChatDetailTitleBar`. Reuse the existing `@State showTopicSheet` binding for both presenters.

**Tech Stack:** Swift / SwiftUI, iOS 16+ / Mac Catalyst, XcodeGen, `xcodebuild`. No XCTest target — verification is `xcodebuild` compile + manual scenarios on simulator (per [`gitchat-ios-native/CLAUDE.md`](../../CLAUDE.md)).

**Spec:** [`2026-05-01-catalyst-topic-popover-design.md`](../specs/2026-05-01-catalyst-topic-popover-design.md)

**User commit policy:** The user (Vincent) commits manually after manual verification — do **not** run `git commit` from any task. Each task ends with a "stage but don't commit" step (`git add` only) and surfaces the change to the user for review.

---

## File Map

| File | Status | Responsibility |
|---|---|---|
| `GitchatIOS/Features/Conversations/Topics/TopicListContent.swift` | **NEW** | Cross-platform body: list / loading / empty / error views, action functions (`load`, `markRead`, `togglePin`, `archive`), realtime subscription. Accepts `showCreate` as `@Binding<Bool>` so wrappers drive the create sheet. |
| `GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift` | **MODIFY (slim)** | iOS wrapper: `NavigationStack { TopicListContent + .toolbar { + button } }` + `.sheet(isPresented: $showCreate) { TopicCreateSheet... .presentationDetents([.medium]) }`. Behavior identical to today. |
| `GitchatIOS/Features/Conversations/Topics/TopicListPopover.swift` | **NEW (Catalyst-only)** | Catalyst wrapper: header `HStack` with title + create button, `TopicListContent`, fixed `.frame(width: 380, height: 520)`, native macOS `.sheet` for create. File-level `#if targetEnvironment(macCatalyst)`. |
| `GitchatIOS/Features/Conversations/ChatDetailView.swift` | **MODIFY** | Gate the root `.sheet(isPresented: $showTopicSheet)` (lines 158-172) with `#if !targetEnvironment(macCatalyst)`. Attach Catalyst-only `.popover(isPresented: $showTopicSheet, …)` to the toolbar `ChatDetailTitleBar` (lines 290-302). |
| `GitchatIOS.xcodeproj/project.pbxproj` | **REGENERATE** | Run `xcodegen generate` after the two new files are created — `xcodebuild` silently skips files not in `project.pbxproj`. |
| `gitchat_extension/docs/contributors/vincent.md` | **MODIFY** | Append a one-line dated entry to "Decisions" section + overwrite "Current" section, per cross-project convention. |

**Files NOT touched (deliberate, do not modify):**
`TopicCreateSheet.swift`, `TopicRow.swift`, `TopicListStore.swift`, `APIClient+Topic.swift`, `TopicSocketEvent.swift`, `TopicColor.swift`, `TopicEmojiPresets.swift`, `MacShellView.swift`, `ConversationsListView.swift`, `Models.swift`, `project.yml`.

---

## Task 1 — Extract `TopicListContent` from `TopicListSheet`

Pure refactor with no behavior change. Move every `@State`, `@StateObject`, action method, and view builder out of `TopicListSheet` into a new `TopicListContent` view, except for the `NavigationStack`, the `.toolbar`, and the outer `.sheet(isPresented: $showCreate) { TopicCreateSheet }`. Convert `showCreate` from a private `@State` into an external `@Binding` so wrappers can present the create sheet from outside.

**Files:**
- Create: `gitchat-ios-native/GitchatIOS/Features/Conversations/Topics/TopicListContent.swift`
- Modify: `gitchat-ios-native/GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift`

- [ ] **Step 1.1: Create `TopicListContent.swift`**

```swift
// gitchat-ios-native/GitchatIOS/Features/Conversations/Topics/TopicListContent.swift
import SwiftUI

/// Cross-platform body for the topic list. Wrapped by `TopicListSheet`
/// (iOS bottom sheet) and `TopicListPopover` (Mac Catalyst popover).
struct TopicListContent: View {
    let parent: Conversation
    let activeTopicId: String?
    @Binding var showCreate: Bool
    let onPickTopic: (Topic) -> Void

    @StateObject private var store = TopicListStore.shared
    @State private var isLoading = true
    @State private var loadError: String?

    private var topics: [Topic] { store.topics(forParent: parent.id) }
    private var pinned: [Topic] {
        topics.filter { store.isLocallyPinned(topicId: $0.id, parentId: parent.id) }
    }
    private var unpinned: [Topic] {
        topics.filter { !store.isLocallyPinned(topicId: $0.id, parentId: parent.id) }
    }

    var body: some View {
        content
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .gitchatTopicEvent)) { note in
                if let evt = note.object as? TopicSocketEvent { store.applyEvent(evt) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            errorBanner(err)
        } else if isLoading && topics.isEmpty {
            loadingPlaceholder
        } else if topics.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { row(for: $0) }
                }
            }
            Section("All topics") {
                ForEach(unpinned) { row(for: $0) }
            }
        }
        .listStyle(.plain)
        .listRowSeparator(.hidden)
    }

    private func row(for topic: Topic) -> some View {
        TopicRow(topic: topic,
                 isActive: topic.id == activeTopicId,
                 isPinned: store.isLocallyPinned(topicId: topic.id, parentId: parent.id)) {
            onPickTopic(topic)
        }
        .macHover()
        .contextMenu { contextMenu(for: topic) }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    @ViewBuilder
    private func contextMenu(for topic: Topic) -> some View {
        Button { Task { await markRead(topic) } } label: {
            Label("Mark as read", systemImage: "checkmark.circle")
        }
        // Pin/Unpin is per-device only (matches the VS Code extension's
        // webview-state pin model). No API call, no permission check.
        let pinned = store.isLocallyPinned(topicId: topic.id, parentId: parent.id)
        Button { togglePin(topic) } label: {
            Label(pinned ? "Unpin" : "Pin",
                  systemImage: pinned ? "pin.slash" : "pin")
        }
        if !topic.is_general {
            Button(role: .destructive) { Task { await archive(topic) } } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("💬").font(.system(size: 48))
            Text("No topics yet").font(.title3).foregroundStyle(.primary)
            Text("Create one to organize discussions")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("+ New Topic") { showCreate = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 140, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 200, height: 12)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .shimmering()
            }
        }
    }

    private func errorBanner(_ err: String) -> some View {
        VStack(spacing: 12) {
            Text(err).font(.subheadline).foregroundStyle(.red)
            Button("Retry") { Task { await load() } }
        }.padding(24)
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true; loadError = nil
        do {
            let fetched = try await APIClient.shared.fetchTopics(parentId: parent.id)
            store.setTopics(fetched, forParent: parent.id)
        } catch { loadError = "Could not load topics — try again" }
        isLoading = false
    }

    private func markRead(_ t: Topic) async {
        store.clearUnread(topicId: t.id, parentId: parent.id)
        try? await APIClient.shared.markTopicRead(parentId: parent.id, topicId: t.id)
    }

    private func togglePin(_ t: Topic) {
        store.togglePin(topicId: t.id, parentId: parent.id)
    }

    private func archive(_ t: Topic) async {
        do {
            _ = try await APIClient.shared.archiveTopic(parentId: parent.id, topicId: t.id)
            store.archive(topicId: t.id, parentId: parent.id)
        } catch let APIError.http(status, body) where status == 403
                                            && (body ?? "").contains("TOPIC_GENERAL_PROTECTED") {
            ToastCenter.shared.show(.error, "Cannot archive General",
                                     "The General topic is protected")
        } catch let APIError.http(status, body) where status == 403 {
            NSLog("[Topic.archive] 403 body=%@", body ?? "<nil>")
            ToastCenter.shared.show(.error, "Could not archive",
                                     "Only the creator or an admin can archive this topic")
        } catch {
            NSLog("[Topic.archive] error=%@", String(describing: error))
            ToastCenter.shared.show(.error, "Could not archive", "Try again")
        }
    }
}
```

Two notable additions vs. today's `TopicListSheet`:
- `.macHover()` on `row(for:)` — no-op on iOS, light highlight on Catalyst.
- `showCreate` is a `@Binding<Bool>` — driven by either wrapper.

- [ ] **Step 1.2: Slim down `TopicListSheet.swift` to a thin iOS wrapper**

Replace the entire file with:

```swift
// gitchat-ios-native/GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift
import SwiftUI

/// iOS / iPad bottom-sheet wrapper around `TopicListContent`.
/// Catalyst uses `TopicListPopover` instead.
struct TopicListSheet: View {
    let parent: Conversation
    let activeTopicId: String?
    let onPickTopic: (Topic) -> Void

    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            TopicListContent(
                parent: parent,
                activeTopicId: activeTopicId,
                showCreate: $showCreate,
                onPickTopic: onPickTopic
            )
            .navigationTitle("Topics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .accessibilityLabel("New Topic")
                }
            }
            .sheet(isPresented: $showCreate) {
                TopicCreateSheet(parent: parent) { newTopic in
                    TopicListStore.shared.append(newTopic, parentId: parent.id)
                }
                .presentationDetents([.medium])
            }
        }
    }
}
```

- [ ] **Step 1.3: Stage but do not commit**

```bash
cd gitchat-ios-native
git add GitchatIOS/Features/Conversations/Topics/TopicListContent.swift \
        GitchatIOS/Features/Conversations/Topics/TopicListSheet.swift
git status
```

Expected: 1 new file (`TopicListContent.swift`), 1 modified file (`TopicListSheet.swift`). **Do not run `git commit`.**

---

## Task 2 — Create `TopicListPopover` (Catalyst-only)

**Files:**
- Create: `gitchat-ios-native/GitchatIOS/Features/Conversations/Topics/TopicListPopover.swift`

- [ ] **Step 2.1: Create `TopicListPopover.swift`**

```swift
// gitchat-ios-native/GitchatIOS/Features/Conversations/Topics/TopicListPopover.swift
#if targetEnvironment(macCatalyst)
import SwiftUI

/// Mac Catalyst topic-list popover. Anchored on `ChatDetailTitleBar`
/// in `ChatDetailView`'s toolbar. Esc and click-out dismiss
/// automatically via SwiftUI.
struct TopicListPopover: View {
    let parent: Conversation
    let activeTopicId: String?
    let onPickTopic: (Topic) -> Void

    @State private var showCreate = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Topics").font(.headline)
                Spacer()
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Topic")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            TopicListContent(
                parent: parent,
                activeTopicId: activeTopicId,
                showCreate: $showCreate,
                onPickTopic: onPickTopic
            )
        }
        .frame(width: 380, height: 520)
        .sheet(isPresented: $showCreate) {
            // Catalyst renders .sheet as a centered native modal — no
            // .presentationDetents (those are iOS-only).
            TopicCreateSheet(parent: parent) { newTopic in
                TopicListStore.shared.append(newTopic, parentId: parent.id)
            }
        }
    }
}
#endif
```

- [ ] **Step 2.2: Stage but do not commit**

```bash
cd gitchat-ios-native
git add GitchatIOS/Features/Conversations/Topics/TopicListPopover.swift
git status
```

Expected: 1 new file added.

---

## Task 3 — Wire popover into `ChatDetailView`

Two surgical edits in `ChatDetailView.swift`:

1. Wrap the existing root `.sheet(isPresented: $showTopicSheet) { ... }` (lines 158-172) with `#if !targetEnvironment(macCatalyst) ... #endif` so Catalyst skips it.
2. Attach `.popover(isPresented: $showTopicSheet, ...)` to the existing `ChatDetailTitleBar` toolbar item (lines 290-302) inside `#if targetEnvironment(macCatalyst) ... #endif`.

The `@State showTopicSheet` declaration at line 48 stays as-is — both the iOS sheet and the Catalyst popover bind to the same state.

**Files:**
- Modify: `gitchat-ios-native/GitchatIOS/Features/Conversations/ChatDetailView.swift`

- [ ] **Step 3.1: Gate the root `.sheet` for non-Catalyst**

In `ChatDetailView.swift`, find the existing block at lines 158-172:

```swift
        .sheet(isPresented: $showTopicSheet) {
            if case .topic(_, let parent) = resolvedTarget {
                TopicListSheet(
                    parent: parent,
                    activeTopicId: resolvedTarget?.conversationId,
                    onPickTopic: { picked in
                        vm.setTarget(.topic(picked, parent: parent))
                        resolvedTarget = .topic(picked, parent: parent)
                        showTopicSheet = false
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
```

Wrap the modifier body with platform gating:

```swift
        #if !targetEnvironment(macCatalyst)
        .sheet(isPresented: $showTopicSheet) {
            if case .topic(_, let parent) = resolvedTarget {
                TopicListSheet(
                    parent: parent,
                    activeTopicId: resolvedTarget?.conversationId,
                    onPickTopic: { picked in
                        vm.setTarget(.topic(picked, parent: parent))
                        resolvedTarget = .topic(picked, parent: parent)
                        showTopicSheet = false
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        #endif
```

Note: SwiftUI modifier chain platform gating with `#if`/`#endif` directly between `.modifier` calls compiles fine in Swift 5+ as long as both branches return a chain of the same root expression.

- [ ] **Step 3.2: Attach Catalyst popover on the toolbar `ChatDetailTitleBar`**

In `ChatDetailView.swift`, find the existing block at lines 290-302:

```swift
            ToolbarItem(placement: .principal) {
                ChatDetailTitleBar(
                    conversation: vm.conversation,
                    vm: vm,
                    onTap: {
                        if case .topic = vm.target {
                            showTopicSheet = true
                        } else if vm.conversation.isGroup {
                            showMembers = true
                        }
                    }
                )
            }
```

Append the popover modifier inside the closure:

```swift
            ToolbarItem(placement: .principal) {
                ChatDetailTitleBar(
                    conversation: vm.conversation,
                    vm: vm,
                    onTap: {
                        if case .topic = vm.target {
                            showTopicSheet = true
                        } else if vm.conversation.isGroup {
                            showMembers = true
                        }
                    }
                )
                #if targetEnvironment(macCatalyst)
                .popover(
                    isPresented: $showTopicSheet,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    if case .topic(_, let parent) = resolvedTarget {
                        TopicListPopover(
                            parent: parent,
                            activeTopicId: resolvedTarget?.conversationId,
                            onPickTopic: { picked in
                                vm.setTarget(.topic(picked, parent: parent))
                                resolvedTarget = .topic(picked, parent: parent)
                                showTopicSheet = false
                            }
                        )
                    }
                }
                #endif
            }
```

- [ ] **Step 3.3: Stage but do not commit**

```bash
cd gitchat-ios-native
git add GitchatIOS/Features/Conversations/ChatDetailView.swift
git status
```

---

## Task 4 — Regenerate Xcode project & verify file membership

`xcodebuild` silently skips `.swift` files that aren't in `project.pbxproj` — confirmation step is critical per `CLAUDE.md`.

- [ ] **Step 4.1: Regenerate the Xcode project**

```bash
cd gitchat-ios-native
xcodegen generate
```

Expected output: `Created project at <path>/GitchatIOS.xcodeproj`.

- [ ] **Step 4.2: Confirm both new files are in `project.pbxproj`**

```bash
cd gitchat-ios-native
grep -c "TopicListContent.swift" GitchatIOS.xcodeproj/project.pbxproj
grep -c "TopicListPopover.swift" GitchatIOS.xcodeproj/project.pbxproj
```

Expected: both ≥ 1 (typically ≥ 2 per file — one in PBXFileReference, one in PBXBuildFile or PBXSourcesBuildPhase).

If either returns 0, abort and inspect `project.yml` — the file is in a directory `xcodegen` is not scanning.

- [ ] **Step 4.3: Stage the regenerated `project.pbxproj`**

```bash
cd gitchat-ios-native
git add GitchatIOS.xcodeproj/project.pbxproj
git status
```

---

## Task 5 — Build verification

Both build paths must compile cleanly. iOS builds the sheet path; Catalyst builds the popover path.

- [ ] **Step 5.1: Build for iOS Simulator**

```bash
cd gitchat-ios-native
xcodebuild \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | tail -50
```

Expected: ends with `** BUILD SUCCEEDED **`. Any compile error in `TopicListContent`, `TopicListSheet`, or `ChatDetailView` blocks here.

- [ ] **Step 5.2: Build for Mac Catalyst**

```bash
cd gitchat-ios-native
xcodebuild \
  -project GitchatIOS.xcodeproj \
  -scheme GitchatIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  build 2>&1 | tail -50
```

Expected: ends with `** BUILD SUCCEEDED **`. Any compile error in `TopicListPopover` or the Catalyst `#if` branch in `ChatDetailView` blocks here.

If a build fails, fix the surfaced error in place — do not patch around it. Common issues:
- Missing `@Binding` propagation in `TopicListContent` call site.
- `.popover` modifier chain placement (must be on the view, not inside the closure).
- File not actually added to `project.pbxproj` (re-run `xcodegen generate`).

---

## Task 6 — Manual scenario verification

**This task requires a booted iOS Simulator and a running Mac Catalyst app.** The user (Vincent) typically has dev environment up — confirm with them before proceeding.

### 6.1 — iPhone regression (sheet path must be unchanged)

iPhone 16 simulator, login as a user with a `topicsEnabled` group:

- [ ] Tap chat header chip → `TopicListSheet` slides from bottom with `.medium` detent.
- [ ] Drag indicator visible at top of sheet.
- [ ] Tap a topic row → sheet dismisses, chat switches to new topic.
- [ ] Tap "+" in toolbar → `TopicCreateSheet` stacks above (sheet on sheet).
- [ ] Long-press a topic row → context menu (Mark as read / Pin / Archive).
- [ ] Empty / loading / error states render correctly within sheet detents.

If any iPhone regression behavior changed, the refactor introduced a bug — do not proceed.

### 6.2 — Mac Catalyst (new popover path)

Catalyst app, same user:

- [ ] Click chat header → popover opens directly under the title bar with arrow up.
- [ ] Popover dimensions are 380×520 and not clipped by default Catalyst window.
- [ ] Topic rows render fully (emoji + name + last preview + timestamp + unread badges).
- [ ] **Hover** a row → background highlights (`.macHover()` via `.hoverEffect(.highlight)`).
- [ ] **Right-click** a row → native macOS context menu at cursor (Mark as read / Pin/Unpin / Archive).
- [ ] Click a topic → popover closes, chat detail switches to that topic.
- [ ] Click "+" in popover header → `TopicCreateSheet` opens as centered native modal (no drag indicator); popover stays visible behind it.
- [ ] Submit create → sheet closes, popover refreshes with new topic; chat does **not** auto-switch.
- [ ] Cancel create (Esc / click outside) → sheet closes, popover state preserved.
- [ ] Press **Esc** with popover focused → popover closes.
- [ ] Click outside popover → popover closes.
- [ ] While popover is open, send a message from another device into a non-active topic → that row's unread badge updates inline.
- [ ] Switch chat in sidebar while popover is open → popover closes automatically.

### 6.3 — Cross-platform smoke

- [ ] DM and non-topic group on iPhone & Catalyst → tapping the header does **not** trigger popover/sheet (`if case .topic` guard short-circuits).

---

## Task 7 — Update contributor log

Per cross-project convention in `gitstar/CLAUDE.md`, all Vincent's work is logged in `gitchat_extension/docs/contributors/vincent.md`.

**Files:**
- Modify: `gitchat_extension/docs/contributors/vincent.md`

- [ ] **Step 7.1: Update Current section + append Decisions entry**

Overwrite the `Current` section with:

```markdown
- **Working on:** `gitchat-ios-native` — Catalyst topic popover (branch `vincent-feat-catalyst-topic-popover`)
- **Date:** 2026-05-01
- **Blockers:** Vincent to manually verify both iOS regression scenarios (§6.1) and Catalyst popover scenarios (§6.2) on simulator + Mac before commit.
```

Append a one-line entry to the `Decisions` section:

```markdown
- 2026-05-01: Feat `gitchat-ios-native` Catalyst topic popover — adapt the iOS topic-list sheet (shipped 2026-04-30) to a Mac Catalyst SwiftUI `.popover` anchored on `ChatDetailTitleBar`. Refactored `TopicListSheet` into `TopicListContent` (cross-platform body) + iOS sheet wrapper; new `TopicListPopover.swift` gated `#if targetEnvironment(macCatalyst)` mirrors the `MacShellView` pattern. Reuses `@State showTopicSheet` binding; gates root `.sheet` to non-Catalyst, attaches `.popover(arrowEdge: .top, attachmentAnchor: .rect(.bounds))` on the toolbar `ChatDetailTitleBar`. `TopicCreateSheet` unchanged (Catalyst auto-renders `.sheet` as centered modal). `.macHover()` and existing `.contextMenu` give hover + right-click for free. Custom-header path (`ChatView.chatHeader`) is gated `#if !targetEnvironment(macCatalyst)` so no second anchor needed. v1.1 deferrals (kept out of scope): `⌘T` shortcut, search filter, last-active-topic memory, 3rd-column split-view layout. Spec: `gitchat-ios-native/docs/superpowers/specs/2026-05-01-catalyst-topic-popover-design.md`. Plan: `…/plans/2026-05-01-catalyst-topic-popover-plan.md`. Did NOT commit — user commits manually after verify.
```

- [ ] **Step 7.2: Stage but do not commit**

```bash
cd gitchat_extension
git add docs/contributors/vincent.md
git status
```

---

## Task 8 — Hand off to user for manual verification + commit

- [ ] **Step 8.1: Summarize staged changes**

```bash
cd gitchat-ios-native && git status
cd gitchat_extension && git status
```

- [ ] **Step 8.2: Surface to Vincent**

Tell Vincent:
1. Build verification: both `iOS Simulator` and `Mac Catalyst` builds passed.
2. Files staged across two repos (`gitchat-ios-native`, `gitchat_extension`) — none committed.
3. Manual scenarios in §6.1 and §6.2 pending Vincent's verification.
4. Vincent commits manually using preferred message format (`type(scope): description`) and PR strategy.

**Do not run `git commit` from this plan.**
