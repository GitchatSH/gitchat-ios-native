# Backend spec: in-app update gate (issue #43)

This document is the handoff spec for the backend work that powers
the iOS in-app update flow (GitHub issue #43). The iOS client work is
already merged under `Core/AppUpdate/`. Until the endpoint below ships,
the client falls back to Apple's public iTunes lookup API directly,
which is enough for the soft-prompt path but **cannot** drive the
force-update gate (iTunes has no `minimumSupportedVersion` concept).

**tl;dr of this spec:** BE is mostly a pass-through for the App Store.
Auto-fetch `latestVersion` / `releaseNotes` / `storeUrl` / `appStoreId`
from iTunes lookup (cache 1h). The only manual pieces are
`minimumSupportedVersion` and `isForceUpdate`, which are policy calls
only the BE team can make.

## 1. `GET /api/v1/app/version`

Public (no auth required).

**Query params**

| name       | type   | required | example |
| ---------- | ------ | -------- | ------- |
| `platform` | string | yes      | `ios`   |

Future values: `android`, `macos`. Return 400 for unknown platforms.

**Response 200**

```json
{
  "latestVersion": "1.4.2",
  "latestBuild": 142,
  "minimumSupportedVersion": "1.2.0",
  "releaseNotes": "Faster message search, fixes for muted chats.",
  "releasedAt": "2026-04-22T03:10:00Z",
  "storeUrl": "https://apps.apple.com/app/id6748491234",
  "appStoreId": "6748491234",
  "isForceUpdate": false
}
```

### Where each field comes from

The response merges **two sources**: data auto-fetched from Apple's
public store, and a small policy row managed by the BE team. Keep the
two separate so nobody has to remember to bump `latestVersion` every
release (Apple already knows).

| field                     | source                           | required | notes |
| ------------------------- | -------------------------------- | -------- | ----- |
| `latestVersion`           | **auto — iTunes lookup**         | yes      | SemVer. Lifted from `results[0].version`. |
| `latestBuild`             | auto — App Store Connect API     | no       | `CFBundleVersion` tiebreak. Skip for v1 — not exposed by iTunes lookup, and the client works without it. |
| `releaseNotes`            | **auto — iTunes lookup**         | no       | `results[0].releaseNotes`. This is the same "What's New" copy the team already writes in App Store Connect, so no separate CMS needed. |
| `releasedAt`              | auto — iTunes lookup             | no       | `results[0].currentVersionReleaseDate`. Informational. |
| `storeUrl`                | **auto — iTunes lookup**         | yes      | `results[0].trackViewUrl`. |
| `appStoreId`              | **auto — iTunes lookup**         | yes      | `results[0].trackId`. Unblocks the ops ticket that was asking for this number manually. |
| `minimumSupportedVersion` | **manual — policy row**          | yes      | Policy decision: "which client versions am I willing to still serve?". Changes only when BE ships a breaking contract change. |
| `isForceUpdate`           | **manual — policy row**          | yes      | Emergency override — forces the entire supported range to update (e.g. security hotfix) without having to bump `minimumSupportedVersion`. |

### Suggested implementation

**Auto-fetch worker** — hit `https://itunes.apple.com/lookup?bundleId=chat.git`
on a 1-hour cron (or a lazy read-through cache with 1h TTL). Cache the
parsed record keyed by platform. iTunes has 1–2h of propagation delay
after App Store "Available for Sale" flips — acceptable for our banner
cadence.

**Policy table** — one row per platform:

```sql
app_version_policy (
  platform                   text primary key,
  minimum_supported_version  text not null,
  is_force_update            boolean not null default false,
  force_update_reason        text,
  updated_by                 text,
  updated_at                 timestamptz
)
```

Endpoint handler = merge iTunes cache + policy row → response. If the
iTunes cache is empty (cold boot, network hiccup), return 503 so the
client keeps its last known state; do NOT return an empty
`latestVersion` — that would tell the client "you're up to date" which
is wrong.

**Fallback if BE team prefers fully manual** — acceptable but not
recommended. Skip the iTunes worker, put all 4 auto fields into the
policy row, and accept the ops tax of bumping on every release. Doc
the workflow in the release checklist so it doesn't get forgotten.

### Caching

OK to cache the endpoint response behind a CDN (TTL ~60s). Clients
already throttle to 1×/hour so the load is trivial; the low CDN TTL
just makes admin policy flips visible quickly.

### Invariants

- `minimumSupportedVersion` must be **monotonically non-decreasing**.
  Decreasing it mid-flight resurrects already-gated clients into the
  app without re-validating they can speak the current contract. BE
  should reject admin writes that lower it.
- `minimumSupportedVersion <= latestVersion` always. If the iTunes
  auto-fetch would ever produce a response violating this (shouldn't
  happen, but possible during a weird rollout), clamp
  `latestVersion = minimumSupportedVersion` for the response rather
  than serving the inconsistent pair.

## 2. HTTP 426 Upgrade Required gate

On **every** API call, if the incoming client is below
`minimumSupportedVersion` (or `isForceUpdate == true` applies to the
calling version), return:

```
HTTP/1.1 426 Upgrade Required
Content-Type: application/json

{
  "minimumSupportedVersion": "1.2.0",
  "latestVersion": "1.4.2",
  "storeUrl": "https://apps.apple.com/app/id<APP_ID>",
  "appStoreId": "<APP_ID>"
}
```

### How BE identifies the client version

The iOS client already sends its version on auth calls via the
`client_id` body field, e.g. `"client_id": "gitchat-ios@1.4.2"`. That
only covers auth endpoints. For a universal 426 gate, add one of:

**Option A (recommended):** require clients to send
`X-App-Version: 1.4.2` and `X-App-Platform: ios` headers on every
authenticated request. iOS will populate these in `APIClient` once BE
decides on the header names.

**Option B:** parse the existing `User-Agent`, which iOS already sends
as `gitchat-ios/1.4.2`. Regex-parse `gitchat-<platform>/<version>`.

Pick one, document it, and the iOS client will send whatever header
BE prefers.

### Client behavior on 426

The iOS client treats 426 as terminal:

- Flips `AppUpdateChecker.state` to `.forceUpdateRequired(...)`.
- Throws `APIError.upgradeRequired` from the request call. **No retry
  loop.** The full-screen cover takes over.

Therefore BE should only return 426 when it truly means "this client
can no longer talk to us" — not for transient issues.

## 3. OneSignal broadcast on release

When a new release is detected on the store (the iTunes auto-fetch
sees `latestVersion` change) OR when the release workflow publishes
manually, send a OneSignal notification to all users with:

```json
{
  "headings": { "en": "Gitchat 1.4.2 is available" },
  "contents": { "en": "<short release notes>" },
  "data": {
    "type": "app_update",
    "version": "1.4.2"
  }
}
```

Firing it off the auto-fetch change is the simplest: the worker
compares the freshly-fetched `latestVersion` against the last-known
value in Redis; on mismatch, dispatch the broadcast. No manual step.

The iOS push handler (`Core/PushManager.swift`) routes
`type == "app_update"` to `AppUpdateChecker.checkNow()`, which bypasses
the 1×/hour throttle and re-fetches the manifest.

Silent (content-available) variant is also fine — the next time the
user opens the app, the banner appears.

## 4. Admin UI / release workflow (optional but recommended)

With `latestVersion` auto-fetched, the only knobs BE team touches are
`minimumSupportedVersion` and `isForceUpdate` — both are foot-guns, so
wrap writes in a small admin surface:

- Show current policy row alongside the auto-fetched store state
  (`latestVersion`, `releasedAt`, `appStoreId`) so admins see the
  whole picture in one place.
- Enforce non-decreasing `minimumSupportedVersion` at the DB + API
  layer, not just client-side.
- Require a reason field for force-update flips, logged to audit.
- Preview how many users would be gated (rough — based on last-seen
  `User-Agent` / `X-App-Version` counts) before committing the change.

## 5. Acceptance

Client-side work is already in `Core/AppUpdate/` and wired into
`RootView` + `PushManager` + `APIClient`. BE side is done when:

- [ ] Worker fetches iTunes lookup for `bundleId=chat.git` on a 1h
  cadence and caches `version`, `releaseNotes`, `trackViewUrl`,
  `trackId`, `currentVersionReleaseDate`.
- [ ] `app_version_policy` table exists with a row per platform for
  `minimum_supported_version` + `is_force_update`.
- [ ] `GET /api/v1/app/version?platform=ios` returns the merged shape
  above, accessible without auth.
- [ ] Endpoint returns 503 (not an empty `latestVersion`) when the
  iTunes cache is cold.
- [ ] Clients below `minimumSupportedVersion` get 426 on any API call,
  with the body shape shown in §2.
- [ ] `minimum_supported_version` can only increase (DB + API guard).
- [ ] OneSignal broadcast fires when the worker detects a new
  `latestVersion`, with `additionalData.type = "app_update"`.

## References

- Issue: https://github.com/GitchatSH/gitchat-ios-native/issues/43
- iOS client files:
  - `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift` — state machine + manifest fetch
  - `GitchatIOS/Core/AppUpdate/AppStoreSheet.swift` — SKStoreProductViewController wrapper
  - `GitchatIOS/Core/AppUpdate/UpdateUI.swift` — banner + force-update view
  - `GitchatIOS/Core/Networking/APIClient.swift` — 426 interceptor
  - `GitchatIOS/Core/PushManager.swift` — `app_update` push type
- Apple reference: https://developer.apple.com/documentation/storekit/skstoreproductviewcontroller
