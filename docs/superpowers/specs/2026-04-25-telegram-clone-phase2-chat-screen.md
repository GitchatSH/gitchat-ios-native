# Phase 2: Chat Screen — Telegram Clone Spec

## Mục tiêu
Chat screen (DM + Group) match trải nghiệm Telegram iOS, **tuân thủ Design System** (`docs/design/DESIGN.md`): 8pt spacing grid, semantic fonts, semantic colors, 44pt touch targets.

## Scope: Option B (Social Messaging) — không voice chat

---

## Sizing Spec (Design System compliant)

Tất cả values snap về 8pt grid (bội số 4/8). Typography dùng SwiftUI semantic fonts. Colors dùng semantic + asset catalog.

| Element | Value | SwiftUI | Grid ✓ |
|---------|-------|---------|--------|
| Bubble max-width | responsive | `min(screenWidth * 0.75, 304)` (304 = 8×38). Catalyst: giữ `BubbleHugLayout` 560pt | ✓ |
| Bubble padding | 8pt 12pt 8pt 12pt | `.padding(.horizontal, 12).padding(.vertical, 8)` | ✓ |
| Bubble border-radius | 20pt (tail corner: 4pt) | `RoundedRectangle(cornerRadius: 20)` | ✓ (20 = 4×5) |
| Bubble font | 17pt regular | `.body` | ✓ |
| Timestamp font | 12pt regular | `.caption` | ✓ |
| Timestamp color (in) | secondary | `.secondary` | — |
| Timestamp color (out) | white 70% | `Color("BubbleMetaOut")` (asset catalog, WCAG AA compliant) | — |
| Checkmark sent | 12×8pt | asset catalog SVG (pre-rendered, not runtime Path) | ✓ |
| Checkmark read | 16×8pt | asset catalog SVG (pre-rendered, not runtime Path) | ✓ |
| Sender name | 13pt semibold | `.footnote.weight(.semibold)` | ✓ |
| Mini avatar (group) | 32pt round | hardcode | ✓ (32 = 8×4) |
| Nav avatar | 36pt (DM: round, Group: bo 12pt) | hardcode | ✓ (36 = 4×9) |
| Same sender gap | 4pt | `spacing: 4` | ✓ |
| Different sender gap | 8pt | `spacing: 8` | ✓ |
| Bubble-to-edge | 8pt | `.padding(.horizontal, 8)` | ✓ |
| Avatar-to-bubble | 8pt | `HStack(spacing: 8)` | ✓ |
| Chat background (light) | warm beige | `Color("ChatBackground")` → `#EFE7DD` | — |
| Chat background (dark) | warm dark | `Color("ChatBackground")` → `#1C1A17` | — |
| Bubble out bg | accent | `Color("AccentColor")` | — |
| Bubble in bg (light) | system bg | `Color(.secondarySystemGroupedBackground)` | — |
| Bubble in bg (dark) | elevated surface | `Color(.secondarySystemGroupedBackground)` (auto dark) | — |
| Accent color | coral | `Color("AccentColor")` (#D16238 in asset catalog) | — |

### Dynamic Type

Bubble max-width scales at accessibility sizes:
- Normal sizes: `min(screenWidth * 0.75, 304)`
- Accessibility sizes (AX1-AX5): `screenWidth * 0.85`
- Check: `UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory`
- Define in ONE place: computed property on `ChatTheme` or similar

### Catalyst Adaptation (từ DESIGN.md §1.5)

- Bubble max-width: giữ existing `BubbleHugLayout` 560pt cho Catalyst detail panel
- Bubble padding/radius: giữ cùng values (scale tốt trên desktop)
- Wrap trong `#if targetEnvironment(macCatalyst)` khi cần override

### Color Rules (từ DESIGN.md §1.4)

Không hardcode hex trong code. Tất cả dùng:
- SwiftUI semantic: `.primary`, `.secondary`
- Asset catalog: `Color("AccentColor")`, `Color("ChatBackground")`, `Color("BubbleMetaOut")`
- Hex chỉ defined trong `Assets.xcassets`, KHÔNG trong Swift code

**Asset catalog entries cần tạo TRƯỚC khi code:**

| Color Set | Light | Dark | Dùng cho |
|-----------|-------|------|----------|
| `ChatBackground` | `#EFE7DD` (warm beige) | `#1C1A17` (warm dark) | Chat screen background |
| `BubbleMetaOut` | `#FFFFFFB3` (white 70%) | `#FFFFFFB3` (white 70%) | Timestamp + checkmarks trên outgoing bubble |
| `SenderColor1` | `#E67E22` | `#F0A050` | Sender name hash color |
| `SenderColor2` | `#3498DB` | `#5DADE2` | Sender name hash color |
| `SenderColor3` | `#9B59B6` | `#BB8FCE` | Sender name hash color |
| `SenderColor4` | `#2ECC71` | `#58D68D` | Sender name hash color |
| `SenderColor5` | `#E74C3C` | `#EC7063` | Sender name hash color |
| `SenderColor6` | `#1ABC9C` | `#48C9B0` | Sender name hash color |
| `SenderColor7` | `#F39C12` | `#F5B041` | Sender name hash color |

### Touch Target Rules (từ DESIGN.md §1.2)

Minimum 44×44pt cho mọi tappable element. Elements nhỏ hơn cần invisible padding:
- Jump buttons 32pt → wrap trong 44×44 touch area
- Reaction pills → `.contentShape(Rectangle())` + `.frame(minHeight: 28)` + padding cho 44pt total. Đặt NGOÀI bubble tap gesture hierarchy để tránh gesture conflict
- Seen avatars 20pt → tap area bao toàn bộ row (44pt height via `.contentShape`)
- Pinned banner X → `xmark` SF Symbol 12pt inside 44×44 touch area

---

## Features

### 1. Đuôi bubble (Bubble Tail)

**Vị trí:** Chỉ tin CUỐI CÙNG trong nhóm tin liên tiếp cùng sender.

**Style:**
- Bezier curve 8×8pt (snap từ Telegram 7×9pt về 8pt grid)
- Tail corner: border-radius 4pt
- Outgoing: bottom-right
- Incoming: bottom-left
- Tin giữa nhóm: full 20pt radius (không tail)

**Implementation (từ Dev Senior review):**
- Tail là DECORATION, KHÔNG phải clip mask
- Content vẫn clip bằng `RoundedRectangle(cornerRadius: 20)` như cũ
- Tail vẽ bằng separate `Path` overlay/underlay tại góc thích hợp, filled cùng bubble color
- Cache `Path` object — `Shape.path(in:)` gọi nhiều lần per layout pass, tránh recompute
- Test trên Catalyst: sub-pixel rendering artifacts với small bezier curves
- Feature flag: `ChatTheme.useBubbleTails` để rollback an toàn

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

**Animation:** Spring animate khi chuyển sent → read. Wrap trong explicit `withAnimation(.spring(...))` inside `.onChange(of: readStatus)`, KHÔNG implicit via state observation. Ensure socket callbacks dispatch to `@MainActor`.

**Inline layout (từ Dev reviews — hardest layout problem):**
- Approach: invisible trailing spacer (`\u{00A0}` non-breaking spaces) + overlay
- Measure timestamp width once via `NSAttributedString.boundingRect`, cache per format
- Append invisible spacer block to message text to reserve room
- Overlay actual timestamp + checkmarks at bottom-trailing
- Budget: 12-14h cho feature này alone
- Checkmark SVGs: pre-rendered assets in `Assets.xcassets` (PDF/SVG), NOT runtime Path drawing

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
- **Scroll timing (P0):** Delay scroll until `applySnapshot` completes + `layoutIfNeeded()`. Use `CATransaction.setCompletionBlock` hoặc `tableView.performBatchUpdates(_:completion:)`. Test với 200+ unread messages.
- Divider persists until user reaches bottom (tất cả messages "seen"), then remove từ data model. KHÔNG fade on scroll-past (match Telegram behavior)
- Remove bằng `reconfigureItems` (swap to empty cell), KHÔNG `deleteItems` (tránh content offset jump trong rotated table)
- Không hiện nếu tất cả đã đọc

**Implementation:**
- Synthetic row type alongside `ChatTypingRowID` / `ChatSeenRowID` pattern
- Set `pendingJumpId` to divider's ID for auto-scroll

**Edge cases (P0):**
- `myReadAt` nil (chưa bao giờ mở) → tất cả là unread, divider ở đầu
- Tin mới đến khi đang trong chat → không di chuyển divider
- 0 tin chưa đọc → không hiện divider

---

### 4. Sender name + màu (Group Only)

**Vị trí:** TRONG bubble, dòng đầu tiên, phía trên text.

**Style:**
- Font: `.footnote.weight(.semibold)` (13pt)
- Màu: **stable hash** từ login string → 1 trong 7 colors defined trong asset catalog:
  ```swift
  // DJB2 hash — deterministic, không random seed như String.hashValue
  let colorIndex = login.utf8.reduce(5381) { ($0 &<< 5) &+ $0 &+ Int($1) } % 7
  Color("SenderColor\(colorIndex + 1)")
  ```
  ```
  SenderColor1...SenderColor7 (orange, blue, purple, green, red, teal, yellow)
  ```
- Compute hash ONCE per message, cache trong dictionary (không recompute trong view body)
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

**Position:** Pseudo-message at bottom of message list (inside ScrollView), NOT overlay. Pushes content up if user is at bottom (match Telegram behavior).

**DM:**
- Typing dots animation only (3 dots bounce)
- Bubble shape: `Color(.secondarySystemGroupedBackground)`, tail left, bottom-left radius 4pt
- Không hiện tên

**Group:**
- Avatar 32pt + typing dots + "alice đang nhập..." (`.caption2`, `.secondary`)
- Nhiều người: "alice, bob đang nhập..." hoặc "3 người đang nhập..."
- Avatar = avatar của người đang gõ

**Timeout:** Tự ẩn sau 5 giây nếu không có follow-up typing event.

---

### 8. 3 Jump Buttons

**Layout:** Xếp dọc, gap 16pt, sticky bottom-right corner trong cbody. Mỗi button 32pt visible, 44×44pt touch target.

**Button style:** `Color(.systemBackground)`, shadow `radius: 4, y: 2, opacity: 0.12`, circle shape 32pt.

**Scroll state (từ Dev Lead review):** Extend existing `isAtBottom: Bool` thành `ChatScrollState` ObservableObject:
- `isAtBottom: Bool`
- `distanceFromBottom: CGFloat`
- `firstVisibleDate: Date?`
- `unreadDividerVisible: Bool`
- Compute badge counts trong Coordinator's `scrollViewDidScroll` using `indexPathsForVisibleRows` (O(1), free).
- Mention precompute: `Set<String>` of message IDs containing `@myLogin`, intersect with off-screen IDs.

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
- Incoming DM: padding-left 12pt
- Incoming Group: padding-left = avatarColumnWidth + spacing = 32 + 8 = 40pt (derived, not magic number)
- Outgoing: padding-right 12pt, trailing-aligned

**Gesture (từ Dev Senior review):**
- Reaction pills PHẢI nằm NGOÀI bubble's `.onTapGesture` view hierarchy (tránh gesture conflict)
- Dùng `.highPriorityGesture(TapGesture())` trên từng pill
- Long-press: `.onLongPressGesture` (OK vì pills không trong rotated table gesture chain)

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
- Background: follow existing `GlassPill.swift` pattern (DESIGN.md §4):
  ```swift
  if #available(iOS 26.0, *) {
      content.glassEffect(.regular, in: Capsule())
  } else {
      content.background(.ultraThinMaterial, in: Capsule())
  }
  ```
- Font: `.footnote.weight(.semibold)`, `.primary`
- Border-radius: Capsule
- Padding: 4pt 12pt (grid-compliant)

**Behavior:**
- Sticky top khi scroll
- Hiện ngày đang xem — detect via Coordinator's `scrollViewDidScroll` using `indexPathsForVisibleRows` (O(1)). KHÔNG dùng SwiftUI PreferenceKey per cell (performance kill với 1000+ messages)
- Publish `firstVisibleDate` từ `ChatScrollState`, SwiftUI overlay reads 1 value
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
- Avatar 20pt (grid: 4×5), border 1pt `Color(.systemBackground)`
- Chồng lên nhau: offset -4pt (grid-compliant)
- Hiện tối đa 5 avatar + "+N" text nếu nhiều hơn

**Behavior:** Tap full row (44pt height via `.contentShape`) → mở SeenBySheet.

**Data:** `readCursors` — members có cursor >= message.created_at.

---

### 14. System Messages (Group Only)

**Style:** Centered, `.caption2`, `.secondary`, italic. Không bubble, không avatar. Vertical padding: 8pt top + 8pt bottom (grid-compliant).

**Types:** Ghim tin / thêm member / rời nhóm / đổi tên / đổi avatar.

---

## Files cần sửa (từ Dev Lead review — 4 new files, not 10)

| File | Thay đổi |
|------|----------|
| `ChatDetailView.swift` | Bubble layout refactor: tail, 2-column group layout, unread divider, seen avatars |
| `ChatMessageView.swift` | Bubble sizing, inline timestamp + checkmarks (invisible spacer + overlay), sender name inside, tail decoration overlay |
| `ChatMessagesList.swift` | `ChatScrollState` ObservableObject, unread divider synthetic row, date pill viewport detection |
| `ChatReactionsRow.swift` | Extend: per-pill tap toggle, long-press picker, `.highPriorityGesture`, 44pt touch targets |
| `JumpToBottomButton.swift` | Rename → `JumpButtonStack.swift`: 3 conditional buttons, `ChatScrollState` driven |
| `ChatNavHeader.swift` | Avatar 36pt, online/last seen, member count, tap target |
| `TypingIndicator.swift` | Group: avatar 32pt + name. DM: dots only. Position: pseudo-message |
| **Mới:** `BubbleShape.swift` | Custom Shape cho bezier tail decoration (separate Path, not clip mask). Cache Path. |
| **Mới:** `UnreadDividerRow.swift` | Synthetic row type (pattern: `ChatTypingRowID`). Remove via `reconfigureItems`. |
| **Mới:** `DatePillOverlay.swift` | Floating date pill overlay. Reads `ChatScrollState.firstVisibleDate`. GlassPill pattern. |
| **Mới:** `PinnedBannerView.swift` | Pinned message banner (group only). Data layer ready (API + socket). |

## Performance Notes (từ Dev Senior review)

- **Date pill:** Use UITableView `indexPathsForVisibleRows` in Coordinator, NOT PreferenceKey per cell
- **Checkmark SVGs:** Pre-rendered assets in `Assets.xcassets`, NOT runtime Path drawing
- **Sender color hash:** Compute once, cache in dictionary. Use stable DJB2 hash.
- **BubbleShape Path:** Cache `CGRect` + `Path`, return cached if rect unchanged
- **Reaction pills:** Cap at 5, use `LazyHStack` or custom `FlowLayout`. No eager `ForEach` in `HStack`.
- **readCursors reconfigure:** Only reconfigure outgoing messages where `created_at` between old and new readAt, not ALL rows
- **Thread safety:** `nonisolated(unsafe) static var seenIds` pattern — consider `OSAllocatedUnfairLock`-protected set
- **`.textSelection(.enabled)` + tap gestures:** Test on iOS 17+ specifically (known SwiftUI bug)

## BE Dependencies

| Feature | Cần BE? | Chi tiết |
|---------|---------|----------|
| Checkmarks | Không | Dùng readCursors từ MessageCache |
| Unread divider | Không | Dùng readCursors[currentUser] |
| Pinned banner | **Confirmed** | `pinnedMessages(conversationId:)` API exists. Socket `onMessagePinned`/`onMessageUnpinned` exists. |
| Typing (group) | **Cần confirm** | subscribe:conversation forward typing events? |
| Reactions | Không (v1) | API reactions đã có. Cần verify WebSocket broadcast |
| Còn lại | Không | Client-side only |

## Estimate (revised — Dev Lead + Dev Senior consensus)

**~100-120h total (2.5-3 sprints).** Original 76-104h +15-20% buffer.

| Sprint | Items | Hours |
|--------|-------|-------|
| **S1** | Bubble sizing + radius 20pt, tail decoration, inline timestamps (hardest: 12-14h), checkmarks, sender name/color, asset catalog setup | 40-48h |
| **S2** | Unread divider (synthetic row + scroll race fix), date pill (Coordinator + GlassPill), jump buttons (`ChatScrollState`), seen avatars 20pt, typing pseudo-message | 36-40h |
| **S3** | Reaction pills (gesture rework), pinned banner, failed retry, save to photos, Catalyst test pass, Dynamic Type test | 24-32h |

## Decisions đã chốt

- Delivery status: Option A — chỉ ✓ sent + ✓✓ read (dùng readCursors, không cần BE change cho delivered)
- Bubble tail: bezier 8×8pt, DECORATION overlay (not clip mask), cache Path, feature flag rollback
- Bubble radius: **20pt** (snapped lên từ Telegram 18pt — grid-legal, closer to Telegram pillowy feel)
- Bubble max-width: **responsive** `min(screenWidth * 0.75, 304)`, AX sizes: `screenWidth * 0.85`, Catalyst: 560pt
- Incoming bubble bg: `Color(.secondarySystemGroupedBackground)` (dark mode safe)
- Timestamp out color: `Color("BubbleMetaOut")` white 70% (WCAG AA compliant, >4.5:1 contrast on coral)
- Sender name: TRONG bubble, `.footnote.weight(.semibold)`, 7 colors in asset catalog, **stable DJB2 hash**
- Sender color hash: `login.utf8.reduce(5381) { ($0 &<< 5) &+ $0 &+ Int($1) } % 7` — deterministic
- Mini avatar: 32pt (snapped từ Telegram 34pt về 8pt grid)
- Seen avatars: **20pt** (from 16pt, border 1pt — legible face)
- Failed send: giữ message (không xóa), icon đỏ bên phải, 44pt touch target, tap retry
- Jump buttons: 3 riêng, 32pt visible + 44pt touch, `Color(.systemBackground)` + shadow, `ChatScrollState` driven
- Reactions: pills NGOÀI bubble tap hierarchy, `.highPriorityGesture`, 44pt touch height
- Unread divider: synthetic row, persist until bottom reached (Telegram behavior), remove via `reconfigureItems`
- Date pill: `GlassPill.swift` pattern (material, not black+blur), viewport detect via Coordinator
- Typing: pseudo-message in list (not overlay), pushes content if at bottom
- Chat background: `Color("ChatBackground")` — light `#EFE7DD`, dark `#1C1A17`
- Dark mode: all asset catalog colors have light+dark variants defined
- All colors: semantic + asset catalog, KHÔNG hardcode hex trong Swift
- All spacing: 8pt grid compliant (4, 8, 12, 16, 20, 24, 32+)
- All typography: SwiftUI semantic fonts (`.body`, `.footnote`, `.caption`, `.caption2`)
- Catalyst: giữ existing `BubbleHugLayout`, wrap overrides trong `#if targetEnvironment(macCatalyst)`
- New files: **4** (BubbleShape, UnreadDividerRow, DatePillOverlay, PinnedBannerView)
- Data mockup: dùng data thật từ app (NorwayIsHere DM, Never Give Up Group)

## 4-Agent Review Summary

| Agent | Score | Key contributions |
|-------|-------|-------------------|
| Trang Nguyễn (Design Lead) | 7.5/10 | Dark mode gaps, missing asset catalog, timestamp contrast, Catalyst adaptation |
| Minh Đức (Design Senior) | 7.5/10 | Bubble radius 16→20pt, responsive max-width, typing position, unread divider behavior |
| Hùng Trần (Dev Lead) | 7.5/10 | Rotated table constraints, 4 new files (not 10), ChatScrollState, estimate 90-120h |
| Linh Phạm (Dev Senior) | 7/10 risk | Inline timestamp approach, scroll race condition, gesture conflicts, BubbleShape as decoration |
