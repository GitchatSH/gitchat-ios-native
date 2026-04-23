#!/usr/bin/env bash
# Bump CFBundleVersion across all targets in project.yml and regenerate
# the Xcode project.
#
# Usage:
#   ./scripts/bump-build.sh            # +1 on current build number
#   ./scripts/bump-build.sh 70         # set build number to 70
#   ./scripts/bump-build.sh 1.0.5 70   # set version = 1.0.5 AND build = 70

set -euo pipefail
cd "$(dirname "$0")/.."

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

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
  echo "regenerated GitchatIOS.xcodeproj"
else
  echo "note: xcodegen not on PATH — run 'xcodegen generate' manually"
fi
