# Chat List — Anchored-Bottom Collection Migration (Level 2 Exploration)

**Date:** 2026-05-04
**Author:** EthanMiller0x — drafted via `superpowers:brainstorming`
**Status:** ⚠️ **Exploration only** — not approved for implementation. Companion to [`2026-05-04-chat-send-jank-fix-design.md`](2026-05-04-chat-send-jank-fix-design.md). Awaiting EthanMiller0x review and approval before any plan/code work.
**Target branch:** TBD (not started)
**Depends on:** `2026-05-04-chat-send-jank-fix-design.md` (b1 should ship first), `docs/architecture/optimistic-send-pipeline.md` (invariants must hold across migration)

---

## 0. Vì sao có spec này

Issue [#104](https://github.com/GitchatSH/gitchat-ios-native/issues/104) `Possible directions` #4:

> **Re-evaluate the rotated-table approach.** The rotation trick makes UITableView's natural "keep top stable" behavior fight the chat's "stick to latest" behavior. An inverted layout (e.g., UICollectionView compositional layout with bottom-to-top reading) may eliminate the entire class of issue.

b1 chỉ patch triệu chứng. Class lỗi (#102 → #103 → #104, và nhiều khả năng các bug "scroll fight back" tiếp theo) sinh ra từ rotated UITableView. Spec này khám phá thay thế.

**Mục tiêu của spec:** Đưa ra bằng chứng đủ để EthanMiller0x quyết định:
- Có nên đầu tư time vào migration không?
- Nếu có, approach nào (3 approach so sánh ở §2)?
- Migration theo strategy nào (full rewrite vs incremental — §3)?
- Risk budget chấp nhận được là gì (§4)?

Spec này KHÔNG đưa ra answer cuối — đó là quyết định của user sau khi đọc.

---

## 1. Hệ quả của rotated-table hiện tại

### 1.1 Bugs đã phát sinh trực tiếp từ rotation

- **#102** — bubble landing behind composer. Root cause: setContentOffset race với diffable apply trên rotated table.
- **#103** — fix #102, race phụ vẫn còn (UIHostingConfiguration multi-pass self-sizing).
- **#104** — fix #103 vẫn để lại jank giữa các snap ticks.
- **#97** — topic message loss during rapid send + back-nav. Tangential nhưng có liên quan đến back-nav timing trên rotated stack.

### 1.2 Code complexity tax

`ChatMessagesList.swift` (~1300 dòng) chứa nhiều block code phải đặc biệt xử lý vì rotation:
- Mỗi cell `.rotationEffect(.degrees(180))` để render upright (5 chỗ trong `configure`).
- "rotation-aware: near bottom = contentOffset near 0" mental model rải rác trong code (`updateUIView:277`, `scrollViewDidScroll:923`, `scrollToBottom:876`).
- `appendItems` reversed order trong snapshot (`apply:793`).
- Pagination: "last section, last row = oldest message visually = top of screen" (`willDisplay:903`).
- Sticky avatar: `cell.convert(cell.bounds, to: window)` correctly handles 180° (chú thích trong code).
- contentInset semantics flip: `top == visual bottom`, `bottom == visual top`.
- `isPrepend` vs `isAppend` check phải làm trong **data space** rồi map sang visual.

Mỗi feature mới cần thêm trên list này phải reason about rotation. Tax tăng theo thời gian.

### 1.3 Edge cases không thể tránh

- Offset-stability cố giữ TOP của data ổn định khi insert ở row 0 → fight với "stick to bottom" semantics → cần hack (triple-snap của #103).
- Self-sizing cell finalize chậm sau diff → contentSize đổi → offset shift visible (root cause #104).
- UIHostingConfiguration không phải fully-deterministic về timing — late shift có thể xảy ra nhiều frames sau apply.

---

## 2. Approaches để thay thế

### 2.1 Approach A: UICollectionView compositional layout với bottom anchor (recommended)

**Cấu trúc:**
- `UICollectionView` với `UICollectionViewCompositionalLayout`.
- KHÔNG xoay 180°. Data-order = visual-order (oldest at top, newest at bottom).
- Custom `UICollectionViewLayoutInvalidationContext`-based anchor: khi `contentSize` đổi và view ở "bottom mode", invalidation context chứa `contentOffsetAdjustment` để giữ visual position.
- Cells dùng `UIHostingConfiguration` (giữ SwiftUI render path hiện có).

**Ưu:**
- Eliminates rotation entirely → giảm complexity tax đáng kể.
- Compositional layout cho phép custom anchoring chuẩn UIKit thay vì hack `setContentOffset`.
- Apple's reference apps (Notes drawing canvas, Messages-app private internals) đều dùng compositional layout cho list-with-anchor patterns.

**Nhược:**
- API mới — toàn bộ delegate methods, prefetch, gesture path, sticky-avatar logic phải port lại.
- Section header / day-pill cần revisit — UICollectionView có khái niệm supplementary view khác UITableView section.
- Estimated 2-3 tuần work nếu ko discover edge case lớn; potentially 4-6 tuần nếu có.

### 2.2 Approach B: Custom UIScrollView + manual layout (full control)

**Cấu trúc:**
- `UIScrollView` thuần, layout cells thủ công với `addSubview` + `setNeedsLayout`.
- Cells = `UIView` wrapping `UIHostingController`.
- Tự quản recycle pool (đơn giản: tất cả cells trong DOM, no recycle — chat list ít khi >500 messages cùng lúc).

**Ưu:**
- Kiểm soát tuyệt đối — zero UIKit auto-behaviors fight back.
- Easier debug — không có hidden offset-stability magic.

**Nhược:**
- Mất tất cả UITableView/CollectionView amenities: cell recycling, prefetch, automatic gesture coordination.
- Phải tự implement: pagination, prefetch, performance under long lists.
- Long-press menu cần custom hit-test path.
- Nhiều rủi ro performance regression — UITableView 10+ năm tuning Apple đã đầu tư.
- Estimated 4-6+ tuần.

### 2.3 Approach C: SwiftUI `ScrollView` + `defaultScrollAnchor(.bottom)` (iOS 17+) (rejected)

**Cấu trúc:**
- Native SwiftUI `ScrollView` + `LazyVStack` + `defaultScrollAnchor(.bottom)`.

**Tại sao reject:**
- iOS 16+ là minimum support (`CLAUDE.md`). `defaultScrollAnchor` là iOS 17+ → không đáp ứng deployment target.
- SwiftUI `ScrollView` có nhiều bug đã được community report về long lists, jank trên rapid update — chính là class issue ta đang muốn loại bỏ.
- Phải drop UIHostingConfiguration → cell sizing path nhỏ hơn nhưng lại lose performance optimizations đã tune trong cell render code.

### 2.4 So sánh

| Tiêu chí | A: Compositional | B: Custom Scroll | C: SwiftUI Scroll |
|---|---|---|---|
| Eliminates rotation class lỗi | ✅ | ✅ | ✅ |
| Effort estimate | 2-3 tuần | 4-6+ tuần | n/a (deployment target) |
| Risk profile | Medium — known UIKit terrain | High — re-implement basics | High — SwiftUI bugs |
| Performance ceiling | Tốt — UIKit-grade | Không chắc | Thấp hơn |
| Migration path | Behind feature flag khả thi | Behind flag khả thi | n/a |
| Long-press / swipe-reply / sticky avatar port | Manageable | Manageable nhưng nặng | Phải redesign |

**Recommendation:** Approach A.

---

## 3. Migration strategy (cho Approach A)

### 3.1 Strategy 1 — Big-bang replace

Một PR thay nguyên `ChatMessagesList.swift` + tất cả call sites. Branch sống lâu, regression khó test.

**Reject:** quá rủi ro với Gitchat shared backend (extension + mobile share BE — bug ở mobile có thể tạo bad data ảnh hưởng extension flows).

### 3.2 Strategy 2 — Behind feature flag (recommended)

- Tạo `ChatMessagesList_v2` (compositional) song song với `ChatMessagesList` hiện tại.
- Feature flag (UserDefaults / env var) chọn implementation tại `ChatView` render time.
- Soak qua TestFlight với một subset users; kiểm tra metrics (crash rate, scroll FPS, send-to-bubble latency).
- Sau soak ổn → flip default → remove flag + old code in một follow-up PR.

**Risk vẫn có:**
- Phải maintain 2 implementations trong vài tuần.
- Cell builder API phải compatible cho cả 2.
- Một số state (`StickyAvatarState`, `BubbleFrameCache`) chia sẻ — cần verify không leak giữa v1/v2 toggling.

### 3.3 Strategy 3 — Incremental cell migration

KHÔNG khả thi: rotation là property ở table-level, không thể migrate per-cell.

---

## 4. Risk Assessment cho Approach A

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Compositional layout không hỗ trợ specific anchor pattern ta cần | Medium | Block migration | POC 3-day spike trước khi commit full plan |
| Long-press menu trên CollectionView không identical với current TableView path | High | UX regression | Test S1-S8 + new automation; có thể cần custom gesture wrapper |
| Sticky-avatar logic (`StickyAvatarState`) hiện đo theo cell convert(window:) — cần re-verify trên unrotated layout | Medium | Avatar offset wrong | Visual regression test |
| Pagination edge logic (`willDisplay last row`) phải đảo ngược (last row visually = newest, không phải oldest) | Low | Pagination broken | Straightforward port |
| BubbleFrameCache hiện có giả định về rotation | Low | Wrong frame trong context menu | Audit cache + adjust |
| Performance regression trên long lists | Low-Medium | Janky scroll | Benchmark trước-sau |
| User devices với on-disk cache `MessageCache` không tương thích | Very Low | Stale UI | Cache version bump nếu cần |

### 4.1 POC trước khi commit

Recommend trước khi viết full plan:
1. **3-day POC**: Standalone branch, build minimal `ChatMessagesList_v2` rendering hard-coded sample messages với compositional layout + bottom anchor. Verify:
   - Rapid-insert 10 cells → bubble lands at bottom mỗi lần, không jump.
   - User scroll up → no auto-yank when new cell inserts.
   - Self-sizing cells với UIHostingConfiguration finalize → anchor giữ visual position.
2. Nếu POC OK → viết full plan.
3. Nếu POC vướng → revisit B/C.

---

## 5. Open questions cần EthanMiller0x trả lời

1. **Timeline:** Có deadline release nào ràng buộc không? Migration trong sprint hiện tại hay quý sau?
2. **Risk appetite:** Behind-flag soak (Strategy 2) chấp nhận được, hay cần ship-or-bust?
3. **Resource:** EthanMiller0x sẽ own migration hay có teammate (vincent? mã ID khác?)?
4. **iOS deployment target:** Có khả năng bump min target iOS 17 trong tương lai gần không? Nếu có, Approach C có thể quay lại bàn.
5. **Đo lường:** Trước migration cần baseline metric nào (FPS scroll, send-to-render latency, memory)? Hiện có hệ analytics đo được không?
6. **Behavior contracts:** Có behavior nào của UITableView hiện tại EthanMiller0x cố ý dựa vào (vd: row animation `.fade` mặc định, automatic scroll-to-row khi keyboard show)? Migration phải replicate hay có thể khác?
7. **Reply-preview parity (out-of-scope b1):** Khi migration đến Level 2, có nên bundle luôn fix reply-preview parity không (đụng `PendingMessage` schema cùng lúc thay vì sau)?

---

## 6. Out of scope của spec này

- Implementation plan — sẽ viết sau khi user approve approach + strategy.
- POC code — chưa start.
- Level 3 (iMessage parity polish: bubble lift, in-bubble upload progress, blurhash pre-sizing) — chỉ bàn sau khi Level 2 ổn định.

---

## 7. Tham chiếu

- Issue #104 — possible direction #4
- b1 spec: `2026-05-04-chat-send-jank-fix-design.md`
- Architecture invariants: `docs/architecture/optimistic-send-pipeline.md`
- Apple WWDC: "Modern cell configuration" (2020), "Compositional layout" (2019, 2020) — public references for compositional layout patterns
