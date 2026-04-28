# CLAUDE.md — Gitchat iOS

Project map for Claude (and humans onboarding fast).

## What this is

Native SwiftUI iOS port of the Gitchat extension. iOS 16+. Bundle id
`chat.git`. Shares the same backend as the extension (defaults to
`api-dev.gitstar.ai` / `ws-dev.gitstar.ai`; see `Core/Config.swift` for
local-dev overrides).

## Project setup

XcodeGen-generated project (see `project.yml`). When you add or rename a
Swift file under `GitchatIOS/`, regenerate before building:

```bash
xcodegen generate
```

`xcodebuild` will silently skip files that aren't in `project.pbxproj`
and report `BUILD SUCCEEDED` anyway, so always confirm new sources made
it in via:

```bash
grep -c "<NewFile>.swift" GitchatIOS.xcodeproj/project.pbxproj
```

## Architecture you must read before touching the chat send path

- [`docs/architecture/optimistic-send-pipeline.md`](docs/architecture/optimistic-send-pipeline.md)
  — how Send → bubble → server-confirmed bubble actually works, and the
  invariants that hold the pipeline together. Several have already been
  broken once and reverted; don't break them again.

## Other docs

- `docs/design/DESIGN.md`, `docs/design/PLANS.md` — overall design notes
- `docs/superpowers/specs/` — feature specs (one per feature)
- `docs/superpowers/plans/` — execution plans (one per spec)
- `README.md` — quick start, build, TestFlight commands

## Conventions

- **No `print()` for app logging** — use `NSLog` (so it shows in
  `xcrun simctl spawn <udid> log stream --process Gitchat`) or
  file-based logs to `/tmp/...` for debugging.
- **No XCTest target yet** — verification is `xcodebuild` compile +
  manual scenarios on a booted simulator. UI automation works via
  `idb` (Facebook's iOS bridge: `brew install facebook/fb/idb-companion`
  + `pip3 install --user fb-idb`).
- **Local API testing** uses the `GitchatIOS local` Xcode scheme which
  sets `API_BASE_URL=http://localhost:3000/api/v1`. Launch from CLI with
  `SIMCTL_CHILD_API_BASE_URL=...` to mimic.

## Backend (cross-repo reference)

- API + WebSocket source: `../gitchat-webapp/backend/` (NestJS).
  See `gitchat-webapp/backend/CLAUDE.md` for backend conventions.
- Local dev DB / Redis / Postgres connection details in
  `gitchat-webapp/backend/.env`.
