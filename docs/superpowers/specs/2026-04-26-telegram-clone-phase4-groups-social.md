# Phase 4: Groups & Social — Telegram Clone Spec

## Mục tiêu
Group management, user profile, members, invite — Telegram-level UX. BE đã support hầu hết endpoints, chỉ cần build UI.

## Scope: Chỉ những gì BE đã support. BE gaps logged ở cuối.

---

## Features

### 1. Members Sheet Polish

**Hiện trạng:** Plain list, không search, không online status, không role badge, không actions.

**Thay đổi:**
- Header: "Members" + count (28)
- Search bar: tìm theo login/name
- Sections: "Online — N" / "Offline — N"
- Avatar: 40px + green dot (online) hoặc no dot (offline)
- Creator badge: `CREATOR` accent tag (9px bold, accent bg)
- Last seen: "online" (green) hoặc "last seen 2h ago" (gray)
- 3-dot menu per member → mở Member Action Sheet
- "Thêm thành viên" button top (accent + icon)

**Data:** `conversation.participants[]` + `PresenceStore` cho online status.

---

### 2. Kick Member

**Trigger:** 3-dot menu trên member row → Action Sheet → "Kick khỏi nhóm"

**Flow:**
1. Tap 3-dot → Member Action Sheet
2. Tap "Kick khỏi nhóm" (destructive, red)
3. Confirm dialog: "Xóa {login} khỏi nhóm?"
4. API: `POST /conversations/:id/kick` body `{ login }`
5. Success → remove from list + system message
6. 403 → toast "Bạn không có quyền"

**Không kick được:** Bản thân mình, creator.

---

### 3. Add Member Flow

**Hiện trạng:** AddMemberSheet có sẵn, cần polish.

**Polish:**
- Search users: `GET /messages/search-users?q=`
- Friend suggestions: từ following list
- Multi-select: checkmark trên avatar
- Mỗi row: avatar 40px + name + login + online dot
- "Thêm" button (accent, disabled khi chưa chọn)
- API: `POST /conversations/:id/members` body `{ login }` (per member)

---

### 4. Group Settings Sheet

**Structure:**
```
[Group Avatar 80px (editable)] [Camera icon overlay]
[Group Name - editable]
[28 thành viên • Tạo bởi slugmacro]

── Thông báo ──
[ Tắt thông báo          [toggle] ]

── Actions ──
[ + Thêm thành viên              ]
[ 🔗 Link mời                     ]
[ ↗ Chuyển tiếp tin nhắn          ]
[ 🔍 Tìm trong cuộc trò chuyện    ]

── Tin ghim ──
[ 📌 3 tin đã ghim            > ]

── Danger Zone ──
[ Rời nhóm          ] (red)
[ Giải tán nhóm     ] (red bold, creator only)
```

**APIs used:**
- Edit name/avatar: `PATCH /conversations/:id/group`
- Avatar upload: `POST /messages/upload` → get URL → patch group
- Mute: `POST/DELETE /conversations/:id/mute`
- Pinned list: `GET /conversations/:id/pinned-messages`

---

### 5. User Profile Sheet

**Trigger:** Tap avatar trong chat, members list, hoặc sender name.

**Structure:**
```
[Avatar 90px + online dot]
[Display Name - 20px bold]
[@login - 14px gray]
[Bio + location - 13px]
[Following] [Message] buttons

── Stats ──
[Repos] [Followers] [Following] [Stars]

── Actions ──
[ Nhắn tin                ]
[ Thêm vào nhóm           ]
[ Chia sẻ profile          ]

── Top Repos ──
[ repo-name • lang • ⭐ N ]
[ repo-name • lang • ⭐ N ]

[ Block user ] (red)
```

**APIs used:**
- Profile: `GET /user/:login` → UserProfile (bio, company, location, repos, followers, top_repos)
- Follow: `PUT /follow/:login` / `DELETE /follow/:login`
- Check follow: `GET /follow/:login` → `{ following, followed_by }`
- Message: navigate to DM conversation

**Follow button states:**
- Not following: "Follow" (accent outlined)
- Following: "Following" (accent filled)
- Mutual: "Following" + "Follows you" label

---

### 6. Invite Link Management

**Structure:**
```
[Group Avatar 64px rounded-square]
[Group Name]
[Member count]

── Link mời ──
[ https://gitchat.sh/join/abc123xyz ]

[Copy link] [Share]

[QR Code 160x160]
Scan để tham gia nhóm

[ Thu hồi link ] (red)
```

**APIs used:**
- Create: `POST /conversations/:id/invite` → `InviteLink { code, url, expires_at }`
- Revoke: `DELETE /conversations/:id/invite`
- Returns existing active link if already created

**QR Code:** Generate từ invite URL bằng `CIFilter("CIQRCodeGenerator")`.

**Share:** `UIActivityViewController` với invite URL.

---

### 7. Leave Group

**Flow:**
1. Group Settings → "Rời nhóm"
2. Confirm: "Bạn sẽ không nhận tin nhắn từ nhóm này nữa. Bạn có chắc?"
3. API: `DELETE /conversations/:id/members/me`
4. Success → dismiss sheet + navigate back to conversation list
5. System message: "{login} đã rời nhóm"

---

### 8. Delete/Disband Group (Creator Only)

**Flow:**
1. Group Settings → "Giải tán nhóm"
2. Confirm 1: "Giải tán nhóm {name}?"
3. Confirm 2: "Tất cả thành viên sẽ bị xóa và lịch sử chat sẽ bị mất. Xác nhận giải tán?"
4. API: `DELETE /conversations/:id/group`
5. 403 → "Chỉ người tạo mới có thể giải tán nhóm"
6. Success → navigate back to conversation list

**UI:** Button chỉ hiện nếu `conversation.creator == currentUser.login` (hoặc always show, rely on 403).

---

### 9. Message Forward

**Trigger:** Long-press message → "Chuyển tiếp"

**Flow:**
1. Conversation picker sheet (search + recent)
2. Multi-select conversations
3. Optional: add comment
4. API: `POST /messages/:id/forward` body `{ conversation_ids: [...] }`
5. Toast "Đã chuyển tiếp đến N cuộc trò chuyện"

---

### 10. Message Edit / Delete

**Edit:**
- Long-press → "Sửa"
- Inline edit mode: composer thay thế bằng edit box, pre-filled với message body
- "Cancel" + "Save" buttons
- API: `PATCH /conversations/:id/messages/:messageId` body `{ body }`
- Edited indicator: "(đã sửa)" nhỏ cạnh timestamp

**Delete/Unsend:**
- Long-press → "Xóa"
- Confirm: "Xóa tin nhắn này?"
- API: `POST /messages/:id/unsend`
- Placeholder: "Tin nhắn đã bị xóa" (italic, gray, centered)

---

### 11. Search in Conversation

**Trigger:** Group Settings → "Tìm trong cuộc trò chuyện" hoặc nav bar search icon.

**Flow:**
1. Search bar overlay trên chat
2. Type query → API: `GET /conversations/:id/search?q=`
3. Results: highlighted matches trong message list
4. Up/down arrows để navigate giữa results
5. Tap result → scroll to message + highlight

---

### 12. Convert DM → Group

**Trigger:** Trong DM, tap "Thêm người" hoặc nav bar action.

**Flow:**
1. User picker (same as Add Member)
2. Chọn 1+ users
3. API: `POST /conversations/:id/convert-to-group`
4. Preserves chat history
5. Navigate to new group conversation
6. System message: "{login} đã tạo nhóm"

---

### 13. Pinned Messages List

**Trigger:** Group Settings → "N tin đã ghim" → chevron.

**Sheet:**
- List tất cả pinned messages (newest first)
- Each row: sender avatar + name + message preview + timestamp
- Tap → dismiss sheet + scroll to message trong chat
- Swipe left → "Unpin" action
- API: `GET /conversations/:id/pinned-messages`

---

## Member Action Sheet

**Trigger:** 3-dot menu trên member row trong Members Sheet.

**Structure:**
```
[Avatar 44px] [Login] [last seen]

── Actions ──
[ 👤 Xem profile      ]
[ 💬 Nhắn tin          ]
[ ➕ Follow             ]

── Destructive ──
[ ❌ Kick khỏi nhóm   ] (red, admin only)

[ Cancel ]
```

---

## Files cần sửa

| File | Thay đổi |
|------|----------|
| `MembersSheet.swift` | Online/offline sections, search, creator badge, 3-dot menu, member count |
| `AddMemberSheet.swift` | Multi-select, friend suggestions, search polish |
| `GroupSettingsSheet.swift` | Full redesign: avatar edit, mute, actions, pinned, leave/delete |
| `GroupInviteLinkSheet.swift` | QR code, copy/share buttons, revoke |
| **Mới:** `UserProfileSheet.swift` | Full profile: avatar, bio, stats, repos, follow, actions |
| **Mới:** `MemberActionSheet.swift` | Per-member actions: profile, message, follow, kick |
| **Mới:** `PinnedMessagesSheet.swift` | List all pinned messages, unpin action |
| **Mới:** `MessageForwardSheet.swift` | Conversation picker for forwarding |
| **Mới:** `ConversationSearchBar.swift` | Search in conversation overlay |
| `ChatDetailView.swift` | Long-press actions: edit, delete, forward |
| `ChatViewModel.swift` | Edit/delete/unsend/forward API calls |
| `ChatNavHeader.swift` | Profile tap target, convert DM action |

## BE Dependencies — Logged cho tương lai

| Item | Priority | Chi tiết |
|------|----------|----------|
| **Admin roles** | BLOCKED | Cần explicit `role` field (owner/admin/member) trong participants. Hiện chỉ có creator check server-side. Không thể hiện admin badge. |
| **Group description** | BLOCKED | Conversation model thiếu `description` field. Cần thêm + PATCH endpoint. |
| **Profile update** | BLOCKED | iOS chưa implement update profile (name, bio, avatar). Cần confirm BE endpoint. |
| **Ban member** | NICE | Chỉ có kick (remove). Ban = block rejoin cần thêm API. |
| **Transfer ownership** | NICE | Creator rời nhóm = nhóm mồ côi. Cần `POST /conversations/:id/transfer-ownership`. |
| **Member join/leave socket events** | NICE | Dedicated events thay vì chỉ detect qua system messages. |

## Estimate

~60-80h total (1.5-2 sprints). Chia 3 đợt:
- **S (0.5 sprint):** Members sheet polish, member action sheet, kick, leave
- **M (1 sprint):** User profile, group settings, invite link, pinned list, add member
- **L (0.5 sprint):** Message forward, edit/delete, search in conversation, convert DM

## Decisions đã chốt

- Creator badge: accent tag "CREATOR" (không có admin vì BE chưa support roles)
- Members sheet: chia Online/Offline sections, search bar
- User profile: show GitHub data (repos, followers, stars) — leveraging existing API
- Kick: 3-dot menu → action sheet → confirm dialog (double step for safety)
- Delete group: double confirm (2 dialogs for destructive action)
- Invite: QR code + copy + share + revoke
- Message forward: multi-select conversations
- Edit: inline edit mode trong composer
- Search: overlay bar trên chat, API-powered
