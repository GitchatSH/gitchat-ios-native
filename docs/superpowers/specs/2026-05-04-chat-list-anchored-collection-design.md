# Chat List — Anchored-Bottom Collection Migration (Level 2 Exploration)

**Date:** 2026-05-04
**Author:** EthanMiller0x — drafted via `superpowers:brainstorming`
**Status:** ⚠️ **Exploration only** — not approved for implementation. Companion to [`2026-05-04-chat-send-jank-fix-design.md`](2026-05-04-chat-send-jank-fix-design.md). Awaiting EthanMiller0x review and approval before any plan/code work.
**Target branch:** TBD (not started)
**Depends on:** `2026-05-04-chat-send-jank-fix-design.md` (b1 should ship first), `docs/architecture/optimistic-send-pipeline.md` (invariants must hold across migration)

---

## 0. Why this spec exists

Issue [#104](https://github.com/GitchatSH/gitchat-ios-native/issues/104) `Possible directions` #4:

> **Re-evaluate the rotated-table approach.** The rotation trick makes UITableView's natural "keep top stable" behavior fight the chat's "stick to latest" behavior. An inverted layout (e.g., UICollectionView compositional layout with bottom-to-top reading) may eliminate the entire class of issue.

b1 only patches the symptom. The class of bugs (#102 → #103 → #104, and likely subsequent "scroll fight back" bugs) stems from the rotated UITableView. This spec explores a replacement.

**Goal of this spec:** Provide enough evidence for EthanMiller0x to decide:
- Is migration worth the time investment?
- If yes, which approach (3 approaches compared in §2)?
- Which migration strategy (full rewrite vs incremental — §3)?
- What's the acceptable risk budget (§4)?

This spec does NOT make the final call — that's the user's decision after reading.

---

## 1. Consequences of the current rotated-table approach

### 1.1 Bugs that originated directly from rotation

- **#102** — bubble landing behind composer. Root cause: setContentOffset race against diffable apply on the rotated table.
- **#103** — fixed #102, but a secondary race remained (UIHostingConfiguration multi-pass self-sizing).
- **#104** — fixed #103 still left jank between snap ticks.
- **#97** — topic message loss during rapid send + back-nav. Tangentially related to back-nav timing on the rotated stack.

### 1.2 Code complexity tax

`ChatMessagesList.swift` (~1300 lines) contains many code blocks that must specifically deal with the rotation:
- Each cell needs `.rotationEffect(.degrees(180))` to render upright (5 sites in `configure`).
- The "rotation-aware: near bottom = contentOffset near 0" mental model is scattered across the code (`updateUIView:277`, `scrollViewDidScroll:923`, `scrollToBottom:876`).
- `appendItems` reversed order in the snapshot (`apply:793`).
- Pagination: "last section, last row = oldest message visually = top of screen" (`willDisplay:903`).
- Sticky avatar: `cell.convert(cell.bounds, to: window)` correctly handles the 180° (per the inline comment).
- contentInset semantics flip: `top == visual bottom`, `bottom == visual top`.
- `isPrepend` vs `isAppend` checks must be done in **data space** then mapped to visual.

Every new feature added on top of this list must reason about rotation. The tax compounds over time.

### 1.3 Edge cases that can't be avoided

- Offset-stability tries to keep the TOP of the data stable when row 0 is inserted → fights the "stick to bottom" semantics → workaround needed (#103's triple-snap).
- Self-sizing cells finalize late after the diff → contentSize changes → offset shift becomes visible (root cause of #104).
- UIHostingConfiguration is not fully deterministic about timing — late shifts can land several frames after apply.

---

## 2. Replacement approaches

### 2.1 Approach A: UICollectionView compositional layout with a bottom anchor (recommended)

**Structure:**
- `UICollectionView` with `UICollectionViewCompositionalLayout`.
- NO 180° rotation. Data-order = visual-order (oldest at top, newest at bottom).
- Custom `UICollectionViewLayoutInvalidationContext`-based anchor: when `contentSize` changes and the view is in "bottom mode", the invalidation context carries `contentOffsetAdjustment` to maintain visual position.
- Cells use `UIHostingConfiguration` (preserves the existing SwiftUI render path).

**Pros:**
- Eliminates rotation entirely → significantly reduces complexity tax.
- Compositional layout supports custom anchoring as a first-class UIKit concept rather than a `setContentOffset` hack.
- Apple's reference apps (Notes drawing canvas, Messages-app private internals) all use compositional layout for list-with-anchor patterns.

**Cons:**
- New API — every delegate method, prefetch, gesture path, sticky-avatar logic has to be ported.
- Section header / day-pill needs revisiting — UICollectionView's supplementary view concept differs from UITableView's section.
- Estimated 2-3 weeks of work absent any major edge cases; potentially 4-6 if any surface.

### 2.2 Approach B: Custom UIScrollView + manual layout (full control)

**Structure:**
- Plain `UIScrollView`, lay out cells manually with `addSubview` + `setNeedsLayout`.
- Cells = `UIView` wrapping a `UIHostingController`.
- Self-managed recycle pool (simplest: keep all cells in the DOM, no recycling — chat lists rarely exceed 500 messages at once).

**Pros:**
- Total control — zero UIKit auto-behaviors fighting back.
- Easier to debug — no hidden offset-stability magic.

**Cons:**
- Lose all UITableView/CollectionView amenities: cell recycling, prefetch, automatic gesture coordination.
- Must self-implement: pagination, prefetch, performance under long lists.
- Long-press menu needs a custom hit-test path.
- High risk of performance regression — UITableView has 10+ years of Apple tuning behind it.
- Estimated 4-6+ weeks.

### 2.3 Approach C: SwiftUI `ScrollView` + `defaultScrollAnchor(.bottom)` (iOS 17+) (rejected)

**Structure:**
- Native SwiftUI `ScrollView` + `LazyVStack` + `defaultScrollAnchor(.bottom)`.

**Why reject:**
- iOS 16+ is the minimum support (`CLAUDE.md`). `defaultScrollAnchor` is iOS 17+ → fails the deployment target.
- SwiftUI `ScrollView` has many community-reported bugs around long lists and rapid-update jank — exactly the class we want to eliminate.
- Forced to drop UIHostingConfiguration → smaller cell sizing path but loses the performance optimizations already tuned in cell render code.

### 2.4 Comparison

| Criterion | A: Compositional | B: Custom Scroll | C: SwiftUI Scroll |
|---|---|---|---|
| Eliminates the rotation bug class | ✅ | ✅ | ✅ |
| Effort estimate | 2-3 weeks | 4-6+ weeks | n/a (deployment target) |
| Risk profile | Medium — known UIKit terrain | High — re-implementing fundamentals | High — SwiftUI bugs |
| Performance ceiling | Good — UIKit-grade | Uncertain | Lower |
| Migration path | Behind feature flag, feasible | Behind flag, feasible | n/a |
| Long-press / swipe-reply / sticky avatar port | Manageable | Manageable but heavy | Needs redesign |

**Recommendation:** Approach A.

---

## 3. Migration strategy (for Approach A)

### 3.1 Strategy 1 — Big-bang replace

A single PR replacing all of `ChatMessagesList.swift` + every call site. Long-lived branch, regression hard to test.

**Reject:** too risky given Gitchat's shared backend (extension + mobile share the BE — a mobile bug can produce bad data that affects extension flows).

### 3.2 Strategy 2 — Behind a feature flag (recommended)

- Create `ChatMessagesList_v2` (compositional) alongside the existing `ChatMessagesList`.
- Feature flag (UserDefaults / env var) selects the implementation at `ChatView` render time.
- Soak with a TestFlight subset of users; track metrics (crash rate, scroll FPS, send-to-bubble latency).
- Once soak passes → flip default → remove flag + old code in a follow-up PR.

**Residual risks:**
- Maintain two implementations for a few weeks.
- Cell builder API must be compatible across both.
- Some state (`StickyAvatarState`, `BubbleFrameCache`) is shared — verify no leakage between v1/v2 toggling.

### 3.3 Strategy 3 — Incremental cell migration

NOT feasible: rotation is a table-level property, can't migrate per cell.

---

## 4. Risk Assessment for Approach A

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Compositional layout doesn't support the specific anchor pattern we need | Medium | Blocks migration | 3-day POC spike before committing to a full plan |
| Long-press menu on CollectionView isn't identical to the current TableView path | High | UX regression | Test S1-S8 + new automation; may need a custom gesture wrapper |
| Sticky-avatar logic (`StickyAvatarState`) currently measures via `cell.convert(window:)` — needs re-verification on the unrotated layout | Medium | Avatar offset wrong | Visual regression test |
| Pagination edge logic (`willDisplay last row`) must be inverted (last row visually = newest, not oldest) | Low | Pagination broken | Straightforward port |
| BubbleFrameCache currently makes rotation-related assumptions | Low | Wrong frame in the context menu | Audit cache + adjust |
| Performance regression on long lists | Low-Medium | Janky scroll | Before/after benchmark |
| User devices with an on-disk `MessageCache` no longer compatible | Very Low | Stale UI | Cache version bump if needed |

### 4.1 POC before committing

Recommended before writing the full plan:
1. **3-day POC**: Standalone branch, build a minimal `ChatMessagesList_v2` rendering hard-coded sample messages with compositional layout + bottom anchor. Verify:
   - Rapid-insert 10 cells → the bubble lands at the bottom every time, no jump.
   - User scrolls up → no auto-yank when a new cell inserts.
   - Self-sizing cells with UIHostingConfiguration finalize → anchor preserves visual position.
2. POC clean → write the full plan.
3. POC blocked → revisit B/C.

---

## 5. Open questions for EthanMiller0x

1. **Timeline:** Any release deadlines that constrain this? Migration in the current sprint or next quarter?
2. **Risk appetite:** Is a behind-flag soak (Strategy 2) acceptable, or do we need ship-or-bust?
3. **Resource:** Will EthanMiller0x own the migration or is there a teammate (Vincent? someone else)?
4. **iOS deployment target:** Any chance of bumping the min target to iOS 17 in the near future? If yes, Approach C reopens.
5. **Measurement:** Pre-migration, what baseline metrics do we need (FPS scroll, send-to-render latency, memory)? Is there an analytics surface to capture them?
6. **Behavior contracts:** Are there UITableView behaviors EthanMiller0x intentionally relies on (e.g., default `.fade` row animation, automatic scroll-to-row on keyboard show)? Must the migration replicate or can it diverge?
7. **Reply-preview parity (out-of-scope b1):** When the migration reaches Level 2, should we bundle the reply-preview parity fix (touching the `PendingMessage` schema at the same time, rather than later)?

---

## 6. Out of scope for this spec

- Implementation plan — written after the user approves approach + strategy.
- POC code — not started.
- Level 3 (iMessage parity polish: bubble lift, in-bubble upload progress, blurhash pre-sizing) — only discussed once Level 2 is stable.

---

## 7. References

- Issue #104 — possible direction #4
- b1 spec: `2026-05-04-chat-send-jank-fix-design.md`
- Architecture invariants: `docs/architecture/optimistic-send-pipeline.md`
- Apple WWDC: "Modern cell configuration" (2020), "Compositional layout" (2019, 2020) — public references for compositional layout patterns
