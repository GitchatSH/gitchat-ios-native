# Gitchat Design — Work Plans

Track công việc đang làm và roadmap liên quan tới design system. Tách khỏi `DESIGN.md` để:
- `DESIGN.md` = **rule hiện tại** (spec, HIG, pattern đã chốt)
- `PLANS.md` = **làm gì tiếp** (roadmap, follow-up, backlog)

Khi xong một plan và pattern đã ổn → move qua `DESIGN.md` dạng spec chính thức, xoá khỏi đây.

---

## 1. Mobile parity roadmap

**Hiện trạng:** `MacRowStyle` áp dụng **chỉ Catalyst**. Mobile giữ values cũ (xem `DESIGN.md` §2.6 iOS fallback).

**Khi sync sang Mobile (session sau):**
1. Trong từng helper của `MacRowStyle.swift`, đổi iOS fallback values → match Catalyst values (avatar 44, subtitle `.subheadline`, meta `.footnote`).
2. Test kỹ trên iPhone vì:
   - Mobile chat list dùng avatar 50pt cho Telegram-feel — đổi 44 có thể "lạ".
   - Caption/meta `.footnote` (13pt) trên iPhone screen có thể chiếm chỗ hơn `.caption2` (11pt).
3. Update `DESIGN.md`: bỏ §2.6 "iOS fallback", merge vào main spec.

---

## 2. Scroll indicator — dứt điểm flicker

**Hiện trạng:** `HideScrollIndicators.swift` dùng single shared `ScrollIndicatorObserver` + KVO + `DispatchWorkItem`, instant alpha 0/1. Cải thiện nhiều nhưng user báo **vẫn flicker nhẹ** khi scroll liên tục.

**Option thử session sau:**
- (a) Gỡ custom alpha control, dùng native `UIScrollView.flashScrollIndicators()` gọi trên mỗi scroll event — cho iOS decide timing.
- (b) Giữ custom nhưng thêm "grace window" ~100ms chống flicker khi KVO fire dồn dập.
- (c) Kiểm tra xem có 2 scroll view lồng nhau (outer List + inner collection) → observer đang chạy trên cái nào.

---

## 3. Unread badges — wire thật

**Hiện trạng:** `MacBottomNav` đang hardcode `unreadChats: 0, unreadActivity: 0` trong `MacShellView.swift`.

**Làm:**
- Expose `unreadCount` từ `ConversationsViewModel` (đã có logic đếm unread ở đâu đó) → pass vào `MacBottomNav`.
- Với Activity, đếm notifications unread từ `NotificationsViewModel`.
- Cân nhắc caching ở `AppRouter` để tránh re-fetch khi nav re-render.

---

## Change log

| Date | Change | Author |
|---|---|---|
| 2026-04-24 | Tách `PLANS.md` khỏi `DESIGN.md`; Mobile parity roadmap move sang đây; thêm scroll flicker + unread badge items | @nakamoto-hiru |
