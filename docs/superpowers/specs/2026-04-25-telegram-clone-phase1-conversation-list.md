# Phase 1: Conversation List — Telegram Clone Spec

## Mục tiêu
Conversation list phải match trải nghiệm Telegram iOS. User mở app lên phải biết ngay trạng thái mọi conversation mà không cần tap vào.

## Scope: Option B (Social Messaging) — không voice chat

---

## Features

### 1. Dấu tích gửi/đọc (Delivery Checkmarks)

**Vị trí:** Cùng dòng timestamp, top-right, trước timestamp.

**States:**
- Tin nhắn gửi đi (outgoing): `✓` xám (#8E8E93) = đã gửi server
- Tin nhắn gửi đi (outgoing): `✓✓` accent (#D16238) = đã đọc
- Tin nhắn nhận (incoming): KHÔNG hiện checkmark

**Logic xác định:**
- "đã gửi" = `last_message.sender == currentUser.login` và message có server `id` (không phải local-id)
- "đã đọc" = `otherReadAt >= last_message.created_at` (lấy từ MessageCache, không cần BE change)
- Group: "đã đọc" = ít nhất 1 member có readCursor >= created_at

**Edge cases (P0):**
- `last_message.created_at` = nil → không hiện checkmark
- `readCursor` = nil (chưa bao giờ mở chat) → fallback "đã gửi"
- Optimistic send (local-id) → không hiện checkmark cho đến khi có server id
- `unsent_at != nil` → không hiện checkmark

**Known limitation:** Conversation chưa bao giờ mở sẽ luôn hiện "đã gửi" thay vì "đã đọc" vì thiếu cache. Cần BE thêm `otherReadAt` vào `listConversations` response để fix trong tương lai.

---

### 2. Đang gõ trong danh sách (Typing in List)

**Hiển thị:** Thay thế preview text bằng typing text accent color (#D16238).

**Format:**
- DM: `"đang nhập..."`
- Group: `"alice đang nhập..."` hoặc `"alice, bob đang nhập..."` hoặc `"3 người đang nhập..."`

**Priority:** Nháp > Typing > Preview (nếu có draft, ẩn typing)

**Implementation:**
- Tạo `TypingStore` singleton (`@MainActor ObservableObject`)
- `@Published var typingByConversation: [String: Set<String>]`
- Bind 1 lần trong `SocketClient.connect()`, lắng nghe tất cả conversation
- `ConversationRow` observe `TypingStore.shared.typingByConversation[convo.id]`
- Filter `login != currentUser.login`

**Edge cases (P0):**
- Typing timeout: tự xóa sau **5 giây** nếu không có follow-up event
- Socket disconnect: clear toàn bộ typing state
- Draft + typing cùng lúc: hiện draft, ẩn typing

**BE dependency:** Cần confirm `subscribe:user` socket event có forward typing events cho tất cả conversation không. Nếu không → BLOCKER, cần BE update.

---

### 3. Bản nháp (Draft Indicator)

**Hiển thị:** `"Nháp: "` (#FF3B30) + draft text, thay thế preview.

**Priority:** Cao nhất (Nháp > Typing > Preview)

**Data source:** `UserDefaults.standard.string(forKey: "gitchat.draft.\(conversation.id)")`

**Edge cases (P0):**
- Draft chỉ whitespace → trim trước, không hiện "Nháp:" nếu empty sau trim
- Draft persistence: đã có sẵn trong UserDefaults, persist qua app kill
- Xóa hết text → draft indicator biến mất ngay (re-render on `.onAppear`)

---

### 4. Nhắc tên @ (Mention Badge)

**Hiển thị:** Badge `@` (#D16238) cạnh unread count badge, bottom-right.

**Logic:** Parse `@currentUser.login` trong `last_message.content`, case-insensitive.

**Điều kiện:** Chỉ hiện khi `displayedUnread > 0` VÀ có mention.

**Edge cases (P0):**
- Case-insensitive: `@SlugMacro` == `@slugmacro`

**Known limitation:** Chỉ check last_message — mention ở tin cũ hơn (vẫn unread) sẽ bị miss. Cần BE thêm `has_mention_unread` field.

---

### 5. Tin chưa đọc (Unread Polish)

**Visual changes:**
- Tên conversation: `font-weight: 700` (bold) khi unread, `600` (semibold) khi đã đọc
- Timestamp: accent color (#D16238) khi unread, gray (#8E8E93) khi đã đọc
- Online dot: green (#34C759) trên avatar khi user online (dùng PresenceStore có sẵn)

---

### 6. Avatar nhóm vuông bo góc

**Group:** Rounded square 62pt, border-radius 18pt. Hiện `group_avatar_url` hoặc chữ cái đầu `group_name` trên nền gradient.

**DM:** Circle 62pt (giữ nguyên).

**Phân biệt:** Dùng `conversation.isGroup` (đã cover `is_group`, `type == "group"`, `"community"`, `"team"`).

**Thay thế hoàn toàn** `GroupAvatarCluster` (stacked circles) bằng single rounded-square avatar.

---

### 7. "You:" prefix + sender avatar trong group

**Group outgoing:** `"You: "` (#D16238) trước preview text. KHÔNG hiện sender avatar.

**Group incoming:** Sender avatar 18pt (round) + sender login trước preview text.

**Quy tắc:**
- KHÔNG hiện "You:" trên system messages (wave, join, leave)
- KHÔNG hiện "You:" trong DM
- KHÔNG hiện "You:" khi last_message.type != "user"

---

### 8. Layout cột phải (Right Column)

**Structure:**
```
[Timestamp + Checkmarks]    ← top-right, cùng dòng
[Pin / Badge / Mute]        ← bottom-right, ngang preview line
```

**Quy tắc bottom-right (ưu tiên):**
- Có unread: unread badge (+ mention badge nếu có)
- Có unread + muted: gray badge + mute icon
- Pinned + không unread: pin icon
- Không gì: empty

---

### 9. Tin hệ thống in nghiêng

**Áp dụng:** Wave, join, leave → `font-style: italic`, color #AEAEB2.

---

### 10. List Pagination

**Hiện trạng:** Chỉ load page đầu (30 conversations). `nextCursor` có trong response nhưng chưa dùng.

**Fix:**
- Thêm `nextCursor` vào `ConversationsViewModel`
- `loadMoreIfNeeded()` trigger khi scroll gần cuối
- Debounce + flag `isLoadingMore` chặn duplicate request
- Dedupe theo `conversation.id` khi merge pages
- Pull-to-refresh reset về page 1

---

## Typography Spec (match Telegram)

| Element | Size | Weight | Color |
|---------|------|--------|-------|
| Title (đã đọc) | 17pt | 600 (semibold) | label |
| Title (chưa đọc) | 17pt | 700 (bold) | label |
| Sender name | 15pt | 500 (medium) | secondary |
| Preview text | 15pt | 400 (regular) | secondary |
| Timestamp (đã đọc) | 14pt | 400 (regular) | #8E8E93 |
| Timestamp (chưa đọc) | 14pt | 400 (regular) | #D16238 |
| Unread badge | 14pt | 700 (bold) | white on #D16238 |

## Layout Spec

| Element | Value |
|---------|-------|
| Avatar size | 62pt |
| Group avatar radius | 18pt |
| Row padding | 9pt vertical, 16pt horizontal |
| Row gap (avatar → content) | 12pt |
| Content gap (title → sender → preview) | 3-4pt |
| Separator inset | 90pt from left |
| Unread badge size | 22pt diameter |
| Online dot | 14pt, border 2.5pt white |
| Sender avatar | 18pt round |

## Files cần sửa

| File | Thay đổi |
|------|----------|
| `ConversationsListView.swift` | ConversationRow refactor: avatar 62pt, right column VStack, checkmarks, draft, typing, mention badge, "You:" prefix, system italic |
| `SocketClient.swift` | Bind TypingStore global trong connect() |
| **Mới:** `TypingStore.swift` | Global typing state singleton |
| `Models.swift` | Không cần thay đổi |

## BE Dependencies

| Feature | Cần BE? | Chi tiết |
|---------|---------|----------|
| Checkmarks | Không (v1) | Dùng MessageCache. Nice-to-have: thêm `otherReadAt` vào listConversations |
| Typing in list | **Cần confirm** | `subscribe:user` có forward typing events? |
| @mention | Không (v1) | Nice-to-have: thêm `has_mention_unread` field |
| Pagination | Không | API đã support cursor |
| Còn lại | Không | Client-side only |

## Estimate

~3-4 ngày dev. Bắt đầu từ S (draft, avatar, mention, layout), sau đó M (checkmarks, typing, pagination).
