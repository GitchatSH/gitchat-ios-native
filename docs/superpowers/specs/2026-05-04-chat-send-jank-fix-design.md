# Chat Send Jank Fix (#104) — Design Spec

**Date:** 2026-05-04
**Author:** EthanMiller0x — drafted via `superpowers:brainstorming`
**Status:** Approved (verbal), proceeding to implementation
**Target branch:** `fix/issue-104-chat-send-jank` off `main`
**Issue:** [#104](https://github.com/GitchatSH/gitchat-ios-native/issues/104) — follow-up to [#102](https://github.com/GitchatSH/gitchat-ios-native/issues/102) / PR [#103](https://github.com/GitchatSH/gitchat-ios-native/pull/103)
**Companion exploration:** [`2026-05-04-chat-list-anchored-collection-design.md`](2026-05-04-chat-list-anchored-collection-design.md) (Level 2 — out of scope here)
**Depends on (must read):** [`docs/architecture/optimistic-send-pipeline.md`](../../architecture/optimistic-send-pipeline.md)

---

## 0. Tóm tắt 1-phút

Sau khi PR #103 đặt bubble đúng chỗ (hết "behind composer"), mỗi lần gửi vẫn thấy bubble "nhảy" nhẹ. Cụ thể: `scrollIfNeeded` của #103 snap `setContentOffset(animated:false)` ba lần trong 3 runloop ticks để win race với `UIHostingConfiguration` cell-sizing. Giữa các snap, `contentSize` đổi (log #103: `4092 → 4051.5`) → bubble visible jump. Trên rapid-send, nhiều snap-sequences chồng lên = chaos.

Fix gồm 2 phần độc lập, đều surgical:

| # | Phần | File |
|---|---|---|
| 1 | **Data parity** ở `OutboxStore.toMessage` (populate `client_message_id`, `attachments`) — pending bubble và server-confirmed bubble render bit-identical cho text + attachments | `GitchatIOS/Core/OutboxStore.swift` |
| 2 | **Settle-aware scroll** thay thế triple-snap — KVO `tableView.contentSize` trong window ≤ 300ms; re-anchor offset mỗi khi contentSize đổi và user vẫn ở đáy; tự stop khi stable hoặc deadline | `GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift` |

Reply-quote pending → server-confirmed transition vẫn còn small reflow (yêu cầu mở rộng `PendingMessage` Codable schema → migration đĩa) → **out of scope b1**, track như v1.1.

Out of scope hoàn toàn: thay rotated UITableView. Nói cách khác b1 không loại bỏ hẳn class lỗi do direction #4 trong issue mô tả; đó là Level 2 trong companion exploration.

---

## 1. Diagnosis

### 1.1 Nguyên nhân #103 vẫn còn jank

Triple-snap là **open-loop**: pin offset tại 3 thời điểm rời rạc (`apply-completion`, `runloop+1`, `runloop+2`). Giữa các điểm này UIKit/SwiftUI có thể đổi `contentSize` mà cơ chế của #103 không phản ứng được. Hệ quả:
- Cell vừa insert (server-id) qua nhiều passes của `UIHostingConfiguration` self-sizing — kích thước intrinsic ổn định sau vài frames, không phải ngay sau diff completion.
- Cell vừa delete (local-cmid) cũng trigger contentSize shrink khi UITableView reclaim row height.
- Trên rapid-send, nhiều `scrollIfNeeded` chains chạy đồng thời — mỗi cái có 3 ticks, không cancel cái cũ → "multiple overlapping snap sequences" mà issue mô tả.

### 1.2 Nguyên nhân thứ hai — data parity gap

`OutboxStore.toMessage` (`OutboxStore.swift:531`) chỉ populate subset của `Message`:
```swift
Message(id: ..., conversation_id: ..., sender: ..., sender_avatar: nil,
        content: p.content, created_at: ..., edited_at: nil,
        reactions: nil, attachment_url: nil, type: "user", reply_to_id: p.replyToID)
```
**Thiếu:** `client_message_id`, `attachments`, `reply`, `reactionRows`, `unsent_at`.

Cho text-only thì pending vs server-confirmed đều có các field này = nil, không gây reflow. Nhưng:
- **Attachments:** `PendingMessage.attachments: [PendingAttachment]` có sẵn (data + mime + w/h). Pending bubble hiện không vẽ thumbnail, server-confirmed vẽ thumbnail → resize lớn (chiều cao 5–10×) khi swap. **Fix ở b1.**
- **Reply preview:** `PendingMessage` chỉ có `replyToID: String?`, không có `ReplyPreview` snapshot → quote-preview chỉ xuất hiện sau khi server confirm → reflow nhỏ (~30–50pt). **Out of scope b1** (cần expand PendingMessage Codable + on-disk migration).

### 1.3 Acceptance từ issue

> Sends look smooth (Telegram / iMessage parity): the bubble appears at the bottom and stays there without visible offset adjustment.

Cụ thể hóa thành measurable AC ở §4.

---

## 2. Phần 1 — Data parity ở `OutboxStore.toMessage`

### 2.1 Thay đổi

```swift
func toMessage(_ p: PendingMessage) -> Message {
    let mappedAttachments: [MessageAttachment]? = p.attachments.isEmpty ? nil :
        p.attachments.map { att in
            MessageAttachment(
                attachment_id: att.clientAttachmentID,
                url: att.uploaded?.url ?? "",
                type: att.mimeType.hasPrefix("image/") ? "image" : "file",
                filename: nil,
                mime_type: att.mimeType,
                width: att.width,
                height: att.height
            )
        }
    return Message(
        id: PendingMessage.optimisticID(for: p.clientMessageID),
        client_message_id: p.clientMessageID,           // NEW
        conversation_id: p.conversationID,
        sender: AuthStore.shared.login ?? "me",
        sender_avatar: nil,
        content: p.content,
        created_at: Self.iso8601.string(from: p.createdAt),
        edited_at: nil,
        reactions: nil,
        attachment_url: nil,
        type: "user",
        reply_to_id: p.replyToID,
        reply: nil,                                     // out-of-scope b1 (Level 2)
        attachments: mappedAttachments,                 // NEW
        unsent_at: nil,
        reactionRows: nil
    )
}
```

Pattern bám theo `Message.optimistic(...)` ở `Models.swift:709` (đã là chuẩn cho legacy flow), tránh tái phát minh mapping.

### 2.2 Invariants check

Đối chiếu `optimistic-send-pipeline.md`:
- **Inv-1** (pending only in OutboxStore, server only in vm.messages, merge in `visibleMessages`): ✅ — vẫn render pending từ store, chỉ đổi cách project sang Message.
- **Inv-4** (pre-stamp createdAt với client tap time): ✅ — vẫn dùng `Self.iso8601.string(from: p.createdAt)`.
- **Inv-5** (ms precision): ✅ — `Self.iso8601` đã set `.withFractionalSeconds`.
- **Inv-6** (không touch `seenIds` từ executeSend success path): n/a, không sửa send flow.

### 2.3 Schema/migration

Không đổi `PendingMessage` Codable → `outbox-pending.json` trên user devices đọc tự động. Không cần migration.

### 2.4 Edge cases

- **Empty attachments** (text-only): `mappedAttachments == nil` — không khác trước → không thay đổi behavior text-only.
- **Attachment chưa upload xong** (`att.uploaded == nil`): map với `url: ""`. UI render path đã chấp nhận empty url (vẽ thumbnail từ local thông qua một path khác đã tồn tại trước b1 — nếu UI hiện tại không xử lý empty url, sẽ surface trong Layer 3 manual scenario S3 và fix tại đó). Lưu ý điều tra trong implementation plan.
- **Attachment đã upload** (`att.uploaded != nil`): dùng `uploaded.url` — bubble pending hiển thị đúng URL, swap sang server-confirmed cùng URL → no reflow.

---

## 3. Phần 2 — Settle-aware scroll thay triple-snap

### 3.1 Cơ chế

Thay block `scrollIfNeeded` (`ChatMessagesList.swift:311–329`) bằng phương thức trên Coordinator:

```swift
// MARK: Anchored scroll (settle-aware)

/// Toggle for verification logging. Set to false before merging.
private static let kAnchorLog = false

private var anchorObservation: NSKeyValueObservation?
private var anchorDeadline: Date?
private var anchorStableTicks: Int = 0
private var anchorStartedAt: Date?

func beginAnchoredScrollToBottom(in tv: UITableView) {
    cancelAnchor(reason: "superseded")  // rapid-send: hủy window cũ trước khi setup window mới

    let snap: () -> Void = { [weak tv] in
        guard let tv else { return }
        tv.layoutIfNeeded()
        tv.setContentOffset(CGPoint(x: 0, y: -tv.contentInset.top), animated: false)
    }
    snap()

    anchorStartedAt = Date()
    anchorDeadline = anchorStartedAt!.addingTimeInterval(0.3)  // hard ceiling
    anchorStableTicks = 0
    if Self.kAnchorLog {
        NSLog("[anchor] start offset=%.2f cs.h=%.2f",
              tv.contentOffset.y, tv.contentSize.height)
    }
    anchorObservation = tv.observe(\.contentSize, options: [.old, .new]) { [weak self, weak tv] _, change in
        guard let self, let tv else { return }
        if let dl = self.anchorDeadline, Date() > dl {
            self.cancelAnchor(reason: "deadline")
            return
        }
        let atBottomThreshold = -tv.contentInset.top + 120
        let atBottom = tv.contentOffset.y < atBottomThreshold
        guard atBottom else {
            self.cancelAnchor(reason: "user-scrolled-up")
            return
        }
        if let old = change.oldValue, let new = change.newValue,
           abs(old.height - new.height) < 0.5 {
            self.anchorStableTicks += 1
            if self.anchorStableTicks >= 2 {
                self.cancelAnchor(reason: "stable")
            }
            return
        }
        self.anchorStableTicks = 0
        snap()
        if Self.kAnchorLog, let old = change.oldValue, let new = change.newValue {
            NSLog("[anchor] kvo cs.h %.2f→%.2f offset=%.2f stable=%d",
                  old.height, new.height, tv.contentOffset.y, self.anchorStableTicks)
        }
    }
}

private func cancelAnchor(reason: String) {
    if Self.kAnchorLog, anchorObservation != nil, let started = anchorStartedAt {
        let durMs = Date().timeIntervalSince(started) * 1000
        NSLog("[anchor] end reason=%@ duration=%.0fms", reason, durMs)
    }
    anchorObservation?.invalidate()
    anchorObservation = nil
    anchorDeadline = nil
    anchorStableTicks = 0
    anchorStartedAt = nil
}
```

Wiring (thay `scrollIfNeeded` block hiện tại):
```swift
let scrollIfNeeded: () -> Void = { [weak tv, weak coord] in
    guard needsScroll, let tv = tv, let coord = coord else { return }
    coord.beginAnchoredScrollToBottom(in: tv)
}
```

Còn lại của `updateUIView` không đổi (animated path / non-animated path đều gọi `scrollIfNeeded`).

### 3.2 Lý do KVO thay vì 2 alternatives

| Approach | Ưu | Nhược | Verdict |
|---|---|---|---|
| **KVO contentSize** (chosen) | đóng vòng kín — bắt mọi contentSize change UIKit gây ra; auto-stop khi stable | KVO trên `UIScrollView.contentSize` không phải fully-documented public; pattern dùng phổ biến trong iOS chat apps thực tế | đủ tin cậy cho b1 |
| Custom `UITableView` subclass override `setContentSize:` | reliable nhất, không phụ thuộc KVO behavior | đụng path khởi tạo `UITableView(frame:style:)` ở `makeUIView`; lan ra cell registration; nặng tay cho 1 fix | **đẩy sang Level 2** — chính là cơ sở cho rotated-table replacement |
| CADisplayLink N frames | đơn giản, frame-driven | wasted work nếu settle 1 frame; có thể miss late shift sau N frames; không có stop condition tự nhiên | rejected |

### 3.3 Stop conditions (3 cơ chế chồng nhau)

1. ContentSize stable 2 KVO ticks liên tiếp (delta < 0.5pt) → `reason=stable`.
2. Hard deadline 300ms từ start → `reason=deadline`.
3. User scroll lên (`offset > -inset.top + 120`) → `reason=user-scrolled-up`.

Khi `beginAnchoredScrollToBottom` gọi lại trên rapid-send, phía đầu tự gọi `cancelAnchor(reason: "superseded")` → ngăn 2 windows chồng lên đồng thời.

### 3.4 Threshold rationale

- **300ms hard ceiling**: PR #103 verification log cho thấy late shift kết thúc trong 2 runloop ticks (~33ms ở 60Hz) sau apply-completion. 300ms là 10× margin, đủ cho slow Catalyst frames và async image-load reflow nếu có.
- **120pt at-bottom threshold**: bám theo `scrollViewDidScroll` `current==true → next = offset < 120` (line 932) — nhất quán với `isAtBottom` semantics đã có.
- **0.5pt delta threshold**: pixel-level noise floor; nhỏ hơn dưới mức mắt người nhìn được; ngăn vòng lặp KVO khi `contentSize` rung lắc 0.01pt.
- **2 stable ticks**: 1 tick có thể là pause giữa 2 layout passes; 2 ticks = thật sự settle.

---

## 4. Acceptance Criteria

### 4.1 Đo định lượng (từ NSLog với `kAnchorLog = true`)

| AC | Tiêu chí |
|---|---|
| **AC1** | Sau dòng `[anchor] end`, đọc lại `tv.contentOffset.y` qua một probe → bằng `-contentInset.top` ± 0.5pt. (Có thể thêm 1 dòng log sau `end` để dump giá trị cuối.) |
| **AC2** | Mọi `[anchor] end` có `duration ≤ 300ms`. |
| **AC3** | Mỗi dòng `[anchor] kvo` có `cs.h` thay đổi ≥ 0.5pt phải kèm `offset = -inset.top` (tức snap đã chạy ngay trong cùng tick). |
| **AC4** | Trong rapid-send: log sequence cho 2 sends liên tiếp phải có pattern `[anchor] start ... [anchor] end reason=superseded ... [anchor] start ...` — KHÔNG được có 2 cặp `[anchor] start` mà ở giữa không có `[anchor] end`. |

### 4.2 Đánh giá UX (manual scenarios)

Chạy trên **iOS simulator** và **Mac Catalyst**:

| # | Scenario | Pass criteria | Type |
|---|---|---|---|
| S1 | Gõ "hello" → Return, đang ở đáy | Bubble appear ở bottom, KHÔNG visible jump khi server confirm | golden — #104 chính |
| S2 | Rapid send 10 lần text ngắn (Return liên tục) | Tất cả bubble theo đúng thứ tự, không chaos, không "re-arrange chaotically" | golden — #104 worst case |
| S3 | Gửi 1 ảnh + caption (chọn từ photo picker) | Bubble pending có thumbnail (từ b1 data parity); khi server confirm KHÔNG resize | golden — b1 data parity |
| S4 | Reply một message rồi Send | Pending bubble chỉ có text, server confirm thêm quote-preview → SẼ có small reflow (known limitation, ngoài scope b1) | regression — verify không tệ hơn hiện tại |
| S5 | Đang scroll lên giữa list, có inbound message từ user khác | KHÔNG yank xuống đáy (anchor không hijack vì atBottom == false) | regression — invariant từ #103 test plan |
| S6 | Send → back out ngay → re-enter | Pending bubble vẫn xuất hiện, sau đó server-confirmed swap mượt | regression — invariant 7 từ optimistic-send-pipeline |
| S7 | Failed send → tap Retry | Scroll-to-bottom đúng | regression — #103 test plan |
| S8 | Gửi từ Mac Catalyst bằng Return + bằng click Send arrow | Cả 2 path đều smooth | regression — #101 không hỏng |

### 4.3 Compile gate

- `xcodebuild` cho `GitchatIOS local` scheme — iOS simulator destination → **BUILD SUCCEEDED**.
- `xcodebuild` cho `GitchatIOS local` scheme — Mac Catalyst destination → **BUILD SUCCEEDED**.
- Không introduce warning mới so với baseline `main`.

---

## 5. Out of Scope

| Item | Lý do | Track ở đâu |
|---|---|---|
| Reply-preview parity (snapshot `ReplyPreview` vào `PendingMessage`) | Đụng Codable schema → cần migration `outbox-pending.json` ở user devices; rủi ro vượt mức cần thiết cho 1 jank fix | Issue v1.1 follow-up (chưa file) |
| Replace rotated UITableView (direction #4 trong issue) | Multi-week refactor; chạm tất cả gesture/menu/sticky-avatar code | Companion spec [`2026-05-04-chat-list-anchored-collection-design.md`](2026-05-04-chat-list-anchored-collection-design.md) |
| Bubble lift animation từ composer (iMessage parity) | Polish layer; cần design pass riêng | Level 3 — chưa file |
| Pre-sized cells với blurhash (loại bỏ self-sizing finalize) | Phụ thuộc Level 2 + attachment pipeline | Level 3 |
| `idb` automation cho rapid-send | Optional (Layer 3.5 trong test plan) — sẽ thử nhưng nếu env không sẵn sàng thì defer | Plan task |

---

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| KVO `contentSize` không fire trong một corner case UIKit nội bộ | Low | Bubble jank vẫn còn cho corner đó | Hard deadline + `cancelAnchor` đảm bảo không leak observer; fallback hành vi = giống hiện tại sau ceiling |
| `mappedAttachments` với `url == ""` làm UI render rỗng | Medium | Pending bubble không có thumbnail như mong đợi | Implementation plan có 1 task riêng để probe rendering với empty url; fix tại điểm render nếu cần |
| Anchor hijack legitimate user scroll (S5) | Low | Annoying — yank xuống khi không nên | At-bottom guard (`offset < -inset.top + 120`); test S5 explicit |
| Removed instrumentation (`kAnchorLog`) bị quên trước merge | Low | Console log noise on production | Reviewer checklist + grep gate trong PR description |

---

## 7. Files thay đổi

| File | Thay đổi | Số dòng ước tính |
|---|---|---|
| `GitchatIOS/Core/OutboxStore.swift` | Mở rộng `toMessage` | ~15 dòng (thêm mappedAttachments + 2 fields trong Message init) |
| `GitchatIOS/Features/Conversations/ChatDetail/List/ChatMessagesList.swift` | Thay `scrollIfNeeded` block; thêm `beginAnchoredScrollToBottom` + `cancelAnchor` + 4 stored properties trên Coordinator | -15 / +60 dòng |
| `docs/superpowers/specs/2026-05-04-chat-send-jank-fix-design.md` | NEW (file này) | ~300 dòng |
| `docs/superpowers/specs/2026-05-04-chat-list-anchored-collection-design.md` | NEW (companion) | ~250 dòng |
| `docs/superpowers/plans/2026-05-04-chat-send-jank-fix-implementation.md` | NEW (sẽ tạo qua writing-plans skill) | ~150 dòng |

KHÔNG thêm/đổi file Swift mới → KHÔNG cần `xcodegen generate`.

---

## 8. References

- Issue: [#104](https://github.com/GitchatSH/gitchat-ios-native/issues/104)
- PR vừa merged: [#103](https://github.com/GitchatSH/gitchat-ios-native/pull/103)
- Issue gốc: [#102](https://github.com/GitchatSH/gitchat-ios-native/issues/102)
- Architecture (must read trước khi sửa send path): `docs/architecture/optimistic-send-pipeline.md`
- Companion exploration: `2026-05-04-chat-list-anchored-collection-design.md`
