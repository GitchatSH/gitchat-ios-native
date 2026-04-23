#!/usr/bin/env bash
# Bump CFBundleVersion across all targets in project.yml and regenerate
# the Xcode project.
#
# Usage:
#   ./scripts/bump-build.sh            # +1 on current build number
#   ./scripts/bump-build.sh 70         # set build number to 70
#   ./scripts/bump-build.sh 1.0.5 70   # set version = 1.0.5 AND build = 70
#
# When triggered from the Xcode Archive pre-action, it also skips the
# bump if another archive bumped within GITCHAT_BUMP_WINDOW seconds
# (default 600 = 10 min). This keeps the build number stable across
# back-to-back iOS + Mac Catalyst archives. Pass an explicit build/version
# on the CLI to override the window.
#
# Env:
#   GITCHAT_BUMP_WINDOW — seconds to treat as "same archive session"
#   GITCHAT_BUMP_FORCE=1 — bypass the window check

set -euo pipefail
cd "$(dirname "$0")/.."

LOCK_FILE="/tmp/gitchat-bump.lock"
WINDOW="${GITCHAT_BUMP_WINDOW:-600}"

# Only apply the window when invoked without explicit args (the common
# pre-action case). Manual `./bump-build.sh 70` always bumps.
if [[ $# -eq 0 && "${GITCHAT_BUMP_FORCE:-0}" != "1" && -f "$LOCK_FILE" ]]; then
  last=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if (( now - last < WINDOW )); then
    echo "skipping bump — previous archive bumped $((now - last))s ago (< ${WINDOW}s)"
    echo "to force, delete $LOCK_FILE or set GITCHAT_BUMP_FORCE=1"
    exit 0
  fi
fi

yml="project.yml"
[[ -f "$yml" ]] || { echo "error: $yml not found"; exit 1; }

current_build=$(grep -m1 '^\s*CFBundleVersion:' "$yml" | sed -E 's/.*"([0-9]+)".*/\1/')
current_version=$(grep -m1 '^\s*CFBundleShortVersionString:' "$yml" | sed -E 's/.*"([^"]+)".*/\1/')

new_version="$current_version"
new_build=""

if [[ $# -eq 0 ]]; then
  new_build=$((current_build + 1))
elif [[ $# -eq 1 ]]; then
  new_build="$1"
elif [[ $# -eq 2 ]]; then
  new_version="$1"
  new_build="$2"
else
  echo "usage: $0 [build] | [version build]"
  exit 1
fi

sed -i.bak -E \
  "s/(CFBundleShortVersionString:[[:space:]]*)\"[^\"]+\"/\1\"$new_version\"/g; \
   s/(CFBundleVersion:[[:space:]]*)\"[0-9]+\"/\1\"$new_build\"/g" \
  "$yml"
rm -f "$yml.bak"

echo "version: $current_version → $new_version"
echo "build:   $current_build → $new_build"

# Stamp the lock so a follow-up archive within $WINDOW seconds skips.
date +%s > "$LOCK_FILE"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
  echo "regenerated GitchatIOS.xcodeproj"
else
  echo "note: xcodegen not on PATH — run 'xcodegen generate' manually"
fi
