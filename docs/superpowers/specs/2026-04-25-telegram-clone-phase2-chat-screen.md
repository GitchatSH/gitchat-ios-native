# Phase 2: Chat Screen — Telegram Clone Spec

## Mục tiêu
Chat screen (DM + Group) match trải nghiệm Telegram iOS, **tuân thủ Design System** (`docs/design/DESIGN.md`): 8pt spacing grid, semantic fonts, semantic colors, 44pt touch targets.

## Scope: Option B (Social Messaging) — không voice chat

---

## Sizing Spec (Design System compliant)

Tất cả values snap về 8pt grid (bội số 4/8). Typography dùng SwiftUI semantic fonts. Colors dùng semantic + asset catalog.

| Element | Value | SwiftUI | Grid ✓ |
|---------|-------|---------|--------|
| Bubble max-width | 280pt (~75% screen) | hardcode OK | ✓ (280 = 8×35) |
| Bubble padding | 8pt 12pt 8pt 12pt | `.padding(.horizontal, 12).padding(.vertical, 8)` | ✓ |
| Bubble border-radius | 16pt (tail corner: 4pt) | `RoundedRectangle(cornerRadius: 16)` | ✓ |
| Bubble font | 17pt regular | `.body` | ✓ |
| Timestamp font | 12pt regular | `.caption` | ✓ |
| Timestamp color (in) | secondary | `.secondary` | — |
| Timestamp color (out) | white 55% | `.white.opacity(0.55)` | — |
| Checkmark sent | 12×8pt | custom SVG | ✓ |
| Checkmark read | 16×8pt | custom SVG | ✓ |
| Sender name | 13pt semibold | `.footnote.weight(.semibold)` | ✓ |
| Mini avatar (group) | 32pt round | hardcode | ✓ (32 = 8×4) |
| Nav avatar | 36pt (DM: round, Group: bo 12pt) | hardcode | ✓ (36 = 4×9) |
| Same sender gap | 4pt | `spacing: 4` | ✓ |
| Different sender gap | 8pt | `spacing: 8` | ✓ |
| Bubble-to-edge | 8pt | `.padding(.horizontal, 8)` | ✓ |
| Avatar-to-bubble | 8pt | `HStack(spacing: 8)` | ✓ |
| Chat background | warm beige | `Color("ChatBackground")` in asset catalog | — |
| Bubble out bg | accent | `Color("AccentColor")` | — |
| Bubble in bg | system bg | `Color(.systemBackground)` | — |
| Accent color | coral | `Color("AccentColor")` (#D16238 in asset catalog) | — |

### Color Rules (từ DESIGN.md §1.4)

Không hardcode hex trong code. Tất cả dùng:
- SwiftUI semantic: `.primary`, `.secondary`, `.white.opacity(0.55)`
- Asset catalog: `Color("AccentColor")`, `Color("ChatBackground")`
- Hex chỉ defined trong `Assets.xcassets`, KHÔNG trong Swift code

### Touch Target Rules (từ DESIGN.md §1.2)

Minimum 44×44pt cho mọi tappable element. Elements nhỏ hơn cần invisible padding:
- Jump buttons 32pt → wrap trong 44×44 touch area
- Reaction pills ~24pt → `.contentShape(Rectangle())` với padding 44pt height
- Seen avatars 14pt → tap area bao toàn bộ row, không per-avatar

---

## Features

### 1. Đuôi bubble (Bubble Tail)

**Vị trí:** Chỉ tin CUỐI CÙNG trong nhóm tin liên tiếp cùng sender.

**Style:**
- Bezier curve 8×8pt (snap từ Telegram 7×9pt về 8pt grid)
- Tail corner: border-radius 4pt
- Outgoing: bottom-right
- Incoming: bottom-left
- Tin giữa nhóm: full 16pt radius (không tail)

**Logic xác định tail:**
- `showTail = nextMessage == nil || nextMessage.sender != currentMessage.sender || timeDiff > 60s`
- Cần thêm `showTail` computed property (hiện chỉ có `showHeader`)

---

### 2. Checkmarks trong bubble (Delivery Status)

**Vị trí:** Inline cùng dòng timestamp, bên phải timestamp. Chỉ outgoing messages.

**States:**
- `✓` `.white.opacity(0.5)` = đã gửi server (có server id)
- `✓✓` `.white` = đã đọc (readCursor >= created_at)

**Sizing:**
- Sent (single): 12×8pt
- Read (double): 16×8pt

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

**Hiển thị:** Dòng kẻ `Color("AccentColor").opacity(0.2)` + text "N tin chưa đọc" (`Color("AccentColor")`, `.caption2.weight(.semibold)`).

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
- Font: `.footnote.weight(.semibold)` (13pt)
- Màu: hash từ login string → 1 trong 7 colors defined trong asset catalog:
  ```
  SenderColor1...SenderColor7 (orange, blue, purple, green, red, teal, yellow)
  ```
- Chỉ hiện ở tin ĐẦU TIÊN trong nhóm tin cùng sender (`showHeader`)

**Avatar 32pt:**
- Bên trái bubble column, sticky bottom (chỉ hiện ở tin cuối cùng trong nhóm)
- 2-column layout: avatar col (32pt, stretch height, align bottom) + bubble col (flex, align leading)
- Gap: 8pt (grid-compliant)
- Avatar ẩn (`.opacity(0)`) cho tin không phải cuối trong nhóm

**KHÔNG áp dụng cho:**
- DM (không sender name, không mini avatar)
- Outgoing messages (không sender name)
- System messages

---

### 5. Pinned Banner (Group Only)

**Vị trí:** Dính dưới nav header, trên chat body.

**Structure:**
- Pin icon (`Color("AccentColor")`, 12pt) + label "Tin ghim" (`.caption2.weight(.semibold)`, accent) + preview text (`.caption`, truncate) + X button (close, 44pt touch target)

**Behavior:**
- Tap banner → scroll đến tin được ghim
- X → ẩn banner (persist per conversation trong UserDefaults)
- Nhiều tin ghim → cycle qua, tap next
- Không hiện nếu conversation chưa có pinned message

**Data source:** `conversation.pinnedMessages` hoặc pin events từ socket.

---

### 6. Online / Last Seen

**DM Header:**
- Online: subtitle "online" (`Color(.systemGreen)`) + green dot trên avatar 36pt
- Offline: "hoạt động X phút trước" (`.secondary`)
- Dùng `PresenceStore` có sẵn

**Group Header:**
- Subtitle: "N thành viên, M online" (`.secondary`, M = `.systemGreen`)
- Avatar: 36pt vuông bo 12pt (grid-compliant)
- Tap subtitle → mở MembersSheet

---

### 7. Typing Indicator

**DM:**
- Typing dots animation only (3 dots bounce)
- Bubble shape: white, tail left, bottom-left radius 4px
- Không hiện tên

**Group:**
- Avatar 32pt + typing dots + "alice đang nhập..." (`.caption2`, `.secondary`)
- Nhiều người: "alice, bob đang nhập..." hoặc "3 người đang nhập..."
- Avatar = avatar của người đang gõ

**Timeout:** Tự ẩn sau 5 giây nếu không có follow-up typing event.

---

### 8. 3 Jump Buttons

**Layout:** Xếp dọc, gap 16pt, sticky bottom-right corner trong cbody. Mỗi button 32pt visible, 44×44pt touch target.

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

**Badge:** 16pt circle, `Color("AccentColor")` background, `.white` text `.caption2.weight(.bold)`, centered phía trên button.

**DM:** Thường chỉ 2 buttons (react + unread). Mention button chỉ hiện nếu có.
**Group:** Có thể cả 3.

---

### 9. Reaction Pills

**Vị trí:** Dưới bubble, align theo hướng bubble:
- Incoming: padding-left align với bubble (DM: 12px, Group: 48px qua avatar column)
- Outgoing: padding-right 12px, flex-end

**Style:**
- Pill: `Color(.systemBackground)`, 1pt border `Color(.separator)`, border-radius 12pt
- Padding: 4pt 8pt (grid-compliant, 44pt touch height via `.contentShape`)
- Emoji + count (`.caption2.weight(.semibold)`, `.secondary`)

**`.mine` highlight (khi mình đã react):**
- Border: `Color("AccentColor")`
- Background: `Color("AccentColor").opacity(0.08)`
- Count color: `Color("AccentColor")`

**Behavior:**
- Tap pill → toggle react/unreact
- Long-press → emoji picker
- Wrap nếu nhiều reactions

**Multiple reactions:** Hiện tối đa 5 emoji types. Nếu > 5 → hiện 4 + "+N" pill.

---

### 10. Retry tin gửi lỗi (Failed Send)

**Hiển thị:**
- Bubble opacity 0.6
- Icon chấm than `Color(.systemRed)` BÊN PHẢI bubble, 16pt circle (44pt touch target)

**Behavior:**
- Tap icon → ActionSheet: "Gửi lại" / "Xóa"
- Giữ message trong list (KHÔNG auto-delete)
- Persist qua app restart

**Logic:** `message.unsent_at != nil` hoặc `message.sendError != nil`

---

### 11. Date Pill Floating

**Style:**
- Dark overlay: `.black.opacity(0.5)` + `.blur(radius: 8)`
- Font: `.footnote.weight(.semibold)`, `.white`
- Border-radius: 12pt
- Padding: 4pt 12pt (grid-compliant)

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
- Avatar 16pt, border 2pt `Color(.systemBackground)`
- Chồng lên nhau: offset -4pt (grid-compliant)
- Hiện tối đa 5 avatar + "+N" text nếu nhiều hơn

**Behavior:** Tap → mở SeenBySheet (danh sách ai đã đọc).

**Data:** `readCursors` — members có cursor >= message.created_at.

---

### 14. System Messages (Group Only)

**Style:** Centered, `.caption2`, `.secondary`, italic. Không bubble, không avatar.

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
- Bubble tail: bezier curve 8×8pt (snapped từ Telegram 7×9 về 8pt grid)
- Bubble radius: 16pt (snapped từ Telegram 18pt về 8pt grid)
- Sender name: TRONG bubble, `.footnote.weight(.semibold)`, 7 colors in asset catalog
- Mini avatar: 32pt (snapped từ Telegram 34pt về 8pt grid)
- Failed send: giữ message (không xóa), icon đỏ bên phải, 44pt touch target, tap retry
- Jump buttons: 3 buttons riêng (@mention, react, unread) — 32pt visible, 44pt touch target
- Reactions: pill style dưới bubble, grid-compliant padding (4pt 8pt), 44pt touch height
- Chat background: `Color("ChatBackground")` trong asset catalog (warm beige)
- All colors: semantic + asset catalog, KHÔNG hardcode hex trong Swift
- All spacing: 8pt grid compliant (4, 8, 12, 16, 20, 24, 32+)
- All typography: SwiftUI semantic fonts (`.body`, `.footnote`, `.caption`, `.caption2`)
- Data mockup: dùng data thật từ app (NorwayIsHere DM, Never Give Up Group)
