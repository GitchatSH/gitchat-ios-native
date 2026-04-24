# Backend spec: in-app update gate (issue #43)

This document is the handoff spec for the backend work that powers
the iOS in-app update flow (GitHub issue #43). The iOS client work is
already merged under `Core/AppUpdate/`. Until the endpoint below ships,
the client falls back to Apple's public iTunes lookup API, which is
enough for the soft-prompt path but **cannot** drive the force-update
gate (no `minimumSupportedVersion` is exposed there).

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
  "storeUrl": "https://apps.apple.com/app/id<APP_ID>",
  "appStoreId": "<APP_ID>",
  "isForceUpdate": false
}
```

**Field semantics**

| field                     | type    | required | notes |
| ------------------------- | ------- | -------- | ----- |
| `latestVersion`           | string  | yes      | SemVer `major.minor.patch`. Drives the "new version available" banner. |
| `latestBuild`             | int     | no       | `CFBundleVersion` / `versionCode`. Tiebreaker when `latestVersion` is the same across builds (hotfix re-release). |
| `minimumSupportedVersion` | string  | yes      | SemVer. Clients below this value are blocked by the full-screen force-update cover. See "426 gate" below. |
| `releaseNotes`            | string  | no       | Short plain-text. Rendered inside both the banner and the force-update view. Keep under ~140 chars for the banner line; longer text is fine for the force-update scrollable body. |
| `releasedAt`              | ISO8601 | no       | Informational — not used by the gate logic, but useful for QA. |
| `storeUrl`                | string  | yes      | Full App Store URL. Used as a fallback when `SKStoreProductViewController` fails to load the product. |
| `appStoreId`              | string  | yes      | Numeric App Store id (no `id` prefix). Required for `SKStoreProductViewController` and the `itms-beta://` deep-link. |
| `isForceUpdate`           | bool    | yes      | Secondary force flag. Set `true` to force-update the entire supported range (e.g. urgent rollout). Independent from `minimumSupportedVersion` — ANY force path trips the full-screen gate. |

**Caching**

OK to cache server-side. Clients cache-bust via `?t=<random>` only when
they need a fresh check (push tap); normal cadence is fine with a short
CDN TTL (~60s) since the client itself throttles to 1×/hour.

**Invariants**

- `minimumSupportedVersion` must be **monotonically non-decreasing**.
  Decreasing it mid-flight resurrects already-gated clients into the
  app without re-validating they can speak the current contract. BE
  should reject admin writes that lower it.
- `minimumSupportedVersion <= latestVersion` always.

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

When a new release is published (after the store build goes live),
send a OneSignal notification to all users with:

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

The iOS push handler (`Core/PushManager.swift`) routes
`type == "app_update"` to `AppUpdateChecker.checkNow()`, which bypasses
the 1×/hour throttle and re-fetches the manifest.

Silent (content-available) variant is also fine — the next time the
user opens the app, the banner appears.

## 4. Admin UI / release workflow (optional but recommended)

Because `minimumSupportedVersion` is a foot-gun (lowering it breaks
the gate; raising it strands users), wrap writes in a small admin
surface:

- Show current `latestVersion` / `minimumSupportedVersion`.
- Enforce non-decreasing `minimumSupportedVersion` at the DB + API
  layer, not just client-side.
- Require a reason field for force-update flips, logged to audit.
- Preview how many users would be gated (rough — based on last-seen
  `User-Agent` / `X-App-Version` counts) before committing the change.

## 5. Acceptance

Client-side work is already in `Core/AppUpdate/` and wired into
`RootView` + `PushManager` + `APIClient`. BE side is done when:

- [ ] `GET /api/v1/app/version?platform=ios` returns the shape above
  and is accessible without auth.
- [ ] Clients below `minimumSupportedVersion` get 426 on any API call.
- [ ] Publishing a new release fires the OneSignal broadcast with
  `type=app_update`.
- [ ] `minimumSupportedVersion` can only increase (BE guard).
- [ ] `appStoreId` is known and returned in both the manifest and the
  426 body (ops blocker: we still need the numeric id from the App
  Store Connect record).

## References

- Issue: https://github.com/GitchatSH/gitchat-ios-native/issues/43
- iOS client files:
  - `GitchatIOS/Core/AppUpdate/AppUpdateChecker.swift` — state machine + manifest fetch
  - `GitchatIOS/Core/AppUpdate/AppStoreSheet.swift` — SKStoreProductViewController wrapper
  - `GitchatIOS/Core/AppUpdate/UpdateUI.swift` — banner + force-update view
  - `GitchatIOS/Core/Networking/APIClient.swift` — 426 interceptor
  - `GitchatIOS/Core/PushManager.swift` — `app_update` push type
- Apple reference: https://developer.apple.com/documentation/storekit/skstoreproductviewcontroller
