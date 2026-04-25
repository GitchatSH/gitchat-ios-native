# Phase 2: Chat Screen — Telegram Clone Spec

## Mục tiêu
Chat screen (DM + Group) phải match trải nghiệm Telegram iOS. Bubble sizing, spacing, reactions, delivery status — tất cả đều phải đúng chuẩn Telegram.

## Scope: Option B (Social Messaging) — không voice chat

---

## Telegram Exact Sizing

| Element | Value |
|---------|-------|
| Bubble max-width | ~75% screen (280px trên 375px) |
| Bubble padding | 7px 12px 6px 12px |
| Bubble border-radius | 18px (tail corner: 4px) |
| Bubble font-size | 17px |
| Bubble line-height | 22px (1.29) |
| Timestamp font | 11px |
| Timestamp color (in) | rgba(0,0,0,0.3) |
| Timestamp color (out) | rgba(255,255,255,0.55) |
| Checkmark sent | 11x8px |
| Checkmark read | 16x8px |
| Sender name | 13.5px semibold |
| Mini avatar (group) | 34px round |
| Nav avatar | 36px (DM: round, Group: bo 10px) |
| Same sender gap | 2px |
| Different sender gap | 8px |
| Bubble-to-edge | 8px |
| Avatar-to-bubble | 6px |
| Chat background | #EFE7DD (warm beige) |

---

## Features

### 1. Đuôi bubble (Bubble Tail)

**Vị trí:** Chỉ tin CUỐI CÙNG trong nhóm tin liên tiếp cùng sender.

**Style:**
- Bezier curve 7x9pt (không phải CSS triangle)
- Tail corner: border-radius 4px
- Outgoing: bottom-right
- Incoming: bottom-left
- Tin giữa nhóm: full 18px radius (không tail)

**Logic xác định tail:**
- `showTail = nextMessage == nil || nextMessage.sender != currentMessage.sender || timeDiff > 60s`
- Cần thêm `showTail` computed property (hiện chỉ có `showHeader`)

---

### 2. Checkmarks trong bubble (Delivery Status)

**Vị trí:** Inline cùng dòng timestamp, bên phải timestamp. Chỉ outgoing messages.

**States:**
- `✓` xám (rgba(255,255,255,0.5)) = đã gửi server (có server id)
- `✓✓` trắng (#fff) = đã đọc (readCursor >= created_at)

**Sizing:**
- Sent (single): 11x8px
- Read (double): 16x8px

**Animation:** Spring animate khi chuyển sent → read.

**Logic:**
- Dùng `readCursors` từ MessageCache (không cần BE change)
- DM: "đã đọc" = đối phương có readCursor >= created_at
- Group: "đã đọc" = ít nhất 1 member (không phải mình) có readCursor >= created_at

**Edge cases (P0):**
- Optimistic send (local-id) → không hiện checkmark
- `unsent_at != nil` (failed) → không hiện checkmark, hiện fail icon thay thế
- readCursor nil → fallback sent

---

### 3. Thanh tin chưa đọc (Unread Divider)

**Hiển thị:** Dòng kẻ accent (#D16238, opacity 0.2) + text "N tin chưa đọc" (#D16238, 11px semibold).

**Vị trí:** Giữa tin đã đọc cuối cùng và tin chưa đọc đầu tiên.

**Logic:**
- Cần `myReadAt` = thời điểm mình đọc conversation lần cuối
- Tin có `created_at > myReadAt` = chưa đọc
- `myReadAt` lấy từ `readCursors[currentUser.login]` hoặc `conversation.lastReadAt`

**Behavior:**
- Auto-scroll đến unread divider khi mở chat
- Fade out sau khi user scroll qua
- Không hiện nếu tất cả đã đọc

**Edge cases (P0):**
- `myReadAt` nil (chưa bao giờ mở) → tất cả là unread, divider ở đầu
- Tin mới đến khi đang trong chat → không di chuyển divider
- 0 tin chưa đọc → không hiện divider

---

### 4. Sender name + màu (Group Only)

**Vị trí:** TRONG bubble, dòng đầu tiên, phía trên text.

**Style:**
- Font: 13.5px semibold
- Màu: hash từ login string → 1 trong 7 màu:
  ```
  #E67E22, #3498DB, #9B59B6, #2ECC71, #E74C3C, #1ABC9C, #F39C12
  ```
- Chỉ hiện ở tin ĐẦU TIÊN trong nhóm tin cùng sender (`showHeader`)

**Avatar 34px:**
- Bên trái bubble column, sticky bottom (chỉ hiện ở tin cuối cùng trong nhóm)
- 2-column layout: `av-col` (34px, stretch height, align-items flex-end) + `bub-col` (flex, align-items flex-start)
- Avatar ẩn (`visibility: hidden`) cho tin không phải cuối trong nhóm

**KHÔNG áp dụng cho:**
- DM (không sender name, không mini avatar)
- Outgoing messages (không sender name)
- System messages

---

### 5. Pinned Banner (Group Only)

**Vị trí:** Dính dưới nav header, trên chat body.

**Structure:**
- Pin icon (#D16238, 13px) + label "Tin ghim" (10px semibold, accent) + preview text (11.5px, truncate) + X button (close)

**Behavior:**
- Tap banner → scroll đến tin được ghim
- X → ẩn banner (persist per conversation trong UserDefaults)
- Nhiều tin ghim → cycle qua, tap next
- Không hiện nếu conversation chưa có pinned message

**Data source:** `conversation.pinnedMessages` hoặc pin events từ socket.

---

### 6. Online / Last Seen

**DM Header:**
- Online: subtitle "online" (#34C759) + green dot trên avatar 36px
- Offline: "hoạt động X phút trước" (#8E8E93)
- Dùng `PresenceStore` có sẵn

**Group Header:**
- Subtitle: "N thành viên, M online" (#8E8E93, M = green)
- Avatar: 36px vuông bo 10px
- Tap subtitle → mở MembersSheet

---

### 7. Typing Indicator

**DM:**
- Typing dots animation only (3 dots bounce)
- Bubble shape: white, tail left, bottom-left radius 4px
- Không hiện tên

**Group:**
- Avatar 34px + typing dots + "alice đang nhập..." (9.5px, #8E8E93)
- Nhiều người: "alice, bob đang nhập..." hoặc "3 người đang nhập..."
- Avatar = avatar của người đang gõ

**Timeout:** Tự ẩn sau 5 giây nếu không có follow-up typing event.

---

### 8. 3 Jump Buttons

**Layout:** Xếp dọc, gap 16px, sticky bottom-right corner trong cbody.

**3 buttons (chỉ hiện khi có data):**

| Button | Icon | Badge | Điều kiện |
|--------|------|-------|-----------|
| @Mention | `@` text (accent) | Số mention chưa đọc | Có mention trong unread messages |
| React | ❤️ emoji | Số reaction mới | Có reaction chưa xem |
| Unread | Chevron down (gray) | Số tin chưa đọc | Có tin dưới viewport chưa đọc |

**Behavior:**
- @Mention: scroll đến tin mention gần nhất
- React: scroll đến tin có reaction mới gần nhất
- Unread: scroll đến tin chưa đọc đầu tiên

**Badge:** 16px circle, accent background, white text 9px bold, centered phía trên button.

**DM:** Thường chỉ 2 buttons (react + unread). Mention button chỉ hiện nếu có.
**Group:** Có thể cả 3.

---

### 9. Reaction Pills

**Vị trí:** Dưới bubble, align theo hướng bubble:
- Incoming: padding-left align với bubble (DM: 12px, Group: 48px qua avatar column)
- Outgoing: padding-right 12px, flex-end

**Style:**
- Pill: white background, 1px border #E5E5EA, border-radius 12px
- Padding: 2px 7px 2px 5px
- Emoji + count (10px semibold, #8E8E93)
- Shadow: 0 0.5px 2px rgba(0,0,0,0.06)

**`.mine` highlight (khi mình đã react):**
- Border: accent (#D16238)
- Background: rgba(209,98,56,0.08)
- Count color: accent

**Behavior:**
- Tap pill → toggle react/unreact
- Long-press → emoji picker
- Wrap nếu nhiều reactions

**Multiple reactions:** Hiện tối đa 5 emoji types. Nếu > 5 → hiện 4 + "+N" pill.

---

### 10. Retry tin gửi lỗi (Failed Send)

**Hiển thị:**
- Bubble opacity 0.6
- Icon chấm than đỏ (#FF3B30) BÊN PHẢI bubble, 16px circle

**Behavior:**
- Tap icon → ActionSheet: "Gửi lại" / "Xóa"
- Giữ message trong list (KHÔNG auto-delete)
- Persist qua app restart

**Logic:** `message.unsent_at != nil` hoặc `message.sendError != nil`

---

### 11. Date Pill Floating

**Style:**
- Dark overlay: rgba(0,0,0,0.5) + backdrop-filter blur(8px)
- Font: 13px bold, white
- Border-radius: 10px
- Padding: 3px 10px

**Behavior:**
- Sticky top khi scroll
- Hiện ngày đang xem (dựa trên messages trong viewport)
- Fade in/out mượt (opacity transition 0.2s)
- Format: "Hôm nay", "Hôm qua", "20 tháng 4"

---

### 12. Save to Photos

**Trigger:** Long-press ảnh trong chat → "Lưu vào Ảnh"

**Implementation:**
- Download full-res image (không dùng thumbnail)
- `PHPhotoLibrary.shared().performChanges`
- Xin permission lần đầu (`NSPhotoLibraryAddUsageDescription`)
- Toast xác nhận "Đã lưu" sau khi save thành công

---

### 13. Seen Avatars (Group Only)

**Vị trí:** Dưới tin outgoing cuối cùng, align right.

**Style:**
- Avatar 14px, border 1.5px white (#F2F1F6)
- Chồng lên nhau: margin-left -3px
- Hiện tối đa 5 avatar + "+N" text nếu nhiều hơn

**Behavior:** Tap → mở SeenBySheet (danh sách ai đã đọc).

**Data:** `readCursors` — members có cursor >= message.created_at.

---

### 14. System Messages (Group Only)

**Style:** Centered, 11px, #8E8E93, italic. Không bubble, không avatar.

**Types:** Ghim tin / thêm member / rời nhóm / đổi tên / đổi avatar.

---

## Files cần sửa

| File | Thay đổi |
|------|----------|
| `ChatDetailView.swift` | Bubble layout refactor: tail, 2-column group layout, reaction pills, unread divider, date pill, jump buttons, seen avatars |
| `MessageBubble.swift` | Bubble sizing (17px, 280px max, 18px radius), inline timestamp + checkmarks, sender name inside, tail shape |
| **Mới:** `BubbleShape.swift` | Custom Shape cho bezier tail |
| **Mới:** `ReactionPillView.swift` | Reaction pill row component |
| **Mới:** `JumpButtonStack.swift` | 3 jump buttons (mention, react, unread) |
| **Mới:** `UnreadDivider.swift` | Unread divider line |
| **Mới:** `PinnedBannerView.swift` | Pinned message banner (group only) |
| **Mới:** `DatePillOverlay.swift` | Floating date pill |
| `ChatNavHeader.swift` | Avatar 36px, online/last seen, member count |
| `TypingIndicator.swift` | Group: avatar + name. DM: dots only |

## BE Dependencies

| Feature | Cần BE? | Chi tiết |
|---------|---------|----------|
| Checkmarks | Không | Dùng readCursors từ MessageCache |
| Unread divider | Không | Dùng readCursors[currentUser] |
| Pinned banner | **Cần confirm** | API có trả pinnedMessages không? Socket có pin event? |
| Typing (group) | **Cần confirm** | subscribe:conversation forward typing events? |
| Reactions | Không (v1) | API reactions đã có. Cần verify WebSocket broadcast |
| Còn lại | Không | Client-side only |

## Estimate

~76-104h total (2-2.5 sprints). Chia 3 đợt:
- **S (1 sprint):** Bubble sizing, tail, inline timestamps, checkmarks, sender name/color
- **M (0.5-1 sprint):** Unread divider, date pill, jump buttons, seen avatars, typing
- **L (0.5 sprint):** Reaction pills, pinned banner, failed retry, save to photos

## Decisions đã chốt

- Delivery status: Option A — chỉ ✓ sent + ✓✓ read (dùng readCursors, không cần BE change cho delivered)
- Bubble tail: bezier curve 7x9pt (không CSS triangle)
- Sender name: TRONG bubble, 7 màu hash login
- Failed send: giữ message (không xóa), icon đỏ bên phải, tap retry
- Jump buttons: 3 buttons riêng (@mention, react, unread) — chỉ hiện button nào có data
- Reactions: pill style dưới bubble, highlight `.mine`, max 5 types
- Chat background: #EFE7DD (warm beige, match Telegram default)
- Data mockup: dùng data thật từ app (NorwayIsHere DM, Never Give Up Group)
