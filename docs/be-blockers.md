# Backend endpoints blocking iOS work

Verified against `docs/swagger.json` on 2026-04-23. The only remaining
iOS feature that can't ship yet is #43 (in-app update notification) —
#25 and #31 turned out to be fully covered by the swagger, the earlier
404s were on wrong paths. Fully resolved blockers removed.

## Issue #43 — In-app update notification (still blocked)

No `/app/version` endpoint in swagger. iOS client cannot ship #43 until
BE adds it.

Need:

```
GET /api/v1/app/version?platform=ios
```

Response shape:

```json
{
  "latestVersion": "1.4.2",
  "latestBuild": 142,
  "minimumSupportedVersion": "1.2.0",
  "releaseNotes": "Faster message search, fixes for muted chats.",
  "releasedAt": "2026-04-22T03:10:00Z",
  "storeUrl": "https://apps.apple.com/app/id<APP_ID>",
  "appStoreId": "<APP_ID>",
  "isForceUpdate": false
}
```

Also required:

- Any API call from a client below `minimumSupportedVersion` should
  return HTTP **426 Upgrade Required** so the client can flip into
  force-update mode.
- OneSignal broadcast on each new release with
  `additionalData = { "type": "app_update", "version": "1.4.2" }` so
  the client can re-check on tap.

Also need from ops: the App Store numeric id for Gitchat (the `idNNNN`
in the `apps.apple.com/app/idNNNN` URL). Used by
`SKStoreProductViewController` so the update sheet opens inside the app
instead of kicking the user out.

## Open questions on existing endpoints (non-blocking)

These are documented but the request/response shapes aren't in the
swagger. iOS will infer from the extension and test live — noting here
so BE can confirm or correct.

### `PATCH /messages/conversations/:id/group` (rename + avatar)

Assumed request body:

```json
{
  "group_name": "new name",
  "group_avatar_url": "https://.../avatar.png"
}
```

The avatar is uploaded separately via the existing `/messages/upload`
endpoint first; the returned URL is passed as `group_avatar_url`. Please
confirm this is the intended flow (vs. a multipart `PATCH` that accepts
the image directly).

### `POST /messages/conversations/:id/invite`

Assumed response:

```json
{
  "code": "abc123",
  "url": "https://gitchat.sh/invite/abc123",
  "expires_at": "2026-05-22T00:00:00Z"
}
```

Please confirm field names.

**Important — the `url` field is currently useless on iOS.** BE returns
`https://dev.gitchat.sh/invite/<code>`; tapping that link in iMessage,
Slack, etc. opens Safari and lands on a `404 Page not found`. Two
separate things need to change on BE before web URLs help:

1. Host `apple-app-site-association` on `gitchat.sh` (and `dev.gitchat.sh`)
   so iOS recognizes the host as a Universal Link for the Gitchat app.
   The AASA JSON needs an `applinks` entry with our team id +
   `chat.git` bundle id and a path pattern like `/invite/*`.
2. Serve a real web page at `/invite/<code>` that either redirects to
   the app (when the user already has it installed — AASA handles this)
   or shows a "Get Gitchat on the App Store" landing page otherwise.

Until that's live, the iOS client deliberately shares the custom
`gitchat://invite/<code>` URL instead of BE's `url` field. Taps on that
scheme open the app directly (works for recipients who have Gitchat
installed; no-ops otherwise, which is still better than a 404).

### `GET /messages/conversations/join/:code`

Assumed response:

```json
{
  "group_name": "...",
  "group_avatar_url": "...",
  "member_count": 12,
  "expires_at": "...",
  "already_member": false
}
```

### `POST /messages/conversations/:id/kick` vs `DELETE /:id/members/:login`

Both are in the swagger. We'll use `POST /kick` (`{ login }` body) since
the extension uses that path. If `DELETE /members/:login` is the
canonical one, let us know and we'll switch.

## Resolved — no longer blocking

- #25 invite links: covered by `POST/DELETE /messages/conversations/:id/invite`
  and `GET/POST /messages/conversations/join/:code`.
- #31 group management: covered by `PATCH /messages/conversations/:id/group`
  (rename + avatar), `DELETE /:id/group` (disband), `POST /:id/kick`,
  `POST /:id/convert-to-group`.
