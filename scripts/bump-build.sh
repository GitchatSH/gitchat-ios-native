#!/usr/bin/env bash
# Bump CFBundleVersion across all targets in project.yml and regenerate
# the Xcode project.
#
# Usage:
#   ./scripts/bump-build.sh            # +1 on current build number in project.yml
#   ./scripts/bump-build.sh 70         # set build number to 70
#   ./scripts/bump-build.sh 1.0.5 70   # set version = 1.0.5 AND build = 70
#   ./scripts/bump-build.sh --sync     # query App Store Connect for the
#                                      # max build on the current version and
#                                      # set to (max + 1). Keeps local build
#                                      # number ahead of everything TestFlight
#                                      # has seen — use before each release.
#
# For --sync to work, set these env vars (e.g. in ~/.zshrc or a local
# .env.asc that you source before running):
#
#   ASC_KEY_ID          — App Store Connect API key id (10-char string)
#   ASC_ISSUER_ID       — your team's issuer id (UUID)
#   ASC_KEY_FILE        — absolute path to the downloaded AuthKey_<id>.p8
#   ASC_APP_ID          — numeric app id from ASC (the number in the app's URL)
#
# Generate a key at https://appstoreconnect.apple.com/access/api — role
# Developer is enough for reading builds.

set -euo pipefail
cd "$(dirname "$0")/.."

yml="project.yml"
[[ -f "$yml" ]] || { echo "error: $yml not found"; exit 1; }

current_build=$(grep -m1 '^\s*CFBundleVersion:' "$yml" | sed -E 's/.*"([0-9]+)".*/\1/')
current_version=$(grep -m1 '^\s*CFBundleShortVersionString:' "$yml" | sed -E 's/.*"([^"]+)".*/\1/')

new_version="$current_version"
new_build=""

fetch_asc_max_build() {
  local required=(ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_FILE ASC_APP_ID)
  for v in "${required[@]}"; do
    if [[ -z "${!v:-}" ]]; then
      echo "error: --sync needs env var $v (see script header)" >&2
      return 1
    fi
  done
  [[ -f "$ASC_KEY_FILE" ]] || { echo "error: ASC_KEY_FILE not found at $ASC_KEY_FILE" >&2; return 1; }

  python3 - "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_FILE" "$ASC_APP_ID" "$current_version" <<'PY'
import sys, json, time, urllib.request, urllib.parse, subprocess, base64, hashlib, hmac

key_id, issuer_id, key_file, app_id, version = sys.argv[1:6]

# Build JWT (ES256) using openssl for signing — avoids external python deps.
header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
now = int(time.time())
claims = {"iss": issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}

def b64(o):
    return base64.urlsafe_b64encode(json.dumps(o, separators=(",", ":")).encode()).rstrip(b"=").decode()

signing_input = f"{b64(header)}.{b64(claims)}"

# Sign with openssl (ES256 DER → r||s).
der = subprocess.check_output(
    ["openssl", "dgst", "-sha256", "-sign", key_file],
    input=signing_input.encode(),
)
# Decode DER ECDSA signature to r||s (64 bytes).
def asn1_ecdsa_to_rs(der):
    assert der[0] == 0x30
    # length = der[1] (possibly multi-byte but 70-72 bytes here so single)
    i = 2
    assert der[i] == 0x02
    rlen = der[i+1]; r = der[i+2:i+2+rlen]; i += 2 + rlen
    assert der[i] == 0x02
    slen = der[i+1]; s = der[i+2:i+2+slen]
    r = r.lstrip(b"\x00").rjust(32, b"\x00")
    s = s.lstrip(b"\x00").rjust(32, b"\x00")
    return r + s

rs = asn1_ecdsa_to_rs(der)
sig_b64 = base64.urlsafe_b64encode(rs).rstrip(b"=").decode()
jwt = f"{signing_input}.{sig_b64}"

# Query all TestFlight + App Store builds for the current marketing version.
params = urllib.parse.urlencode({
    "filter[app]": app_id,
    "filter[preReleaseVersion.version]": version,
    "sort": "-uploadedDate",
    "limit": "200",
    "fields[builds]": "version",
})
url = f"https://api.appstoreconnect.apple.com/v1/builds?{params}"
req = urllib.request.Request(url, headers={"Authorization": f"Bearer {jwt}"})
try:
    resp = urllib.request.urlopen(req, timeout=20)
except urllib.error.HTTPError as e:
    print(f"ASC API error: {e.code} {e.read().decode()[:300]}", file=sys.stderr)
    sys.exit(2)

data = json.loads(resp.read())
builds = [int(b["attributes"]["version"]) for b in data.get("data", []) if b.get("attributes", {}).get("version", "").isdigit()]
if not builds:
    # Also check the App Store version channel (released builds).
    print("0")
else:
    print(max(builds))
PY
}

if [[ $# -eq 0 ]]; then
  new_build=$((current_build + 1))
elif [[ "$1" == "--sync" ]]; then
  echo "querying App Store Connect for max build on version ${current_version}..."
  asc_max=$(fetch_asc_max_build)
  next=$((asc_max + 1))
  # Keep the local value if it's already ahead of ASC.
  if (( next <= current_build )); then
    echo "local build ($current_build) is already ≥ ASC max ($asc_max) + 1 — bumping +1 locally"
    new_build=$((current_build + 1))
  else
    echo "ASC max build on ${current_version} = $asc_max -> setting local to $next"
    new_build="$next"
  fi
elif [[ $# -eq 1 ]]; then
  new_build="$1"
elif [[ $# -eq 2 ]]; then
  new_version="$1"
  new_build="$2"
else
  echo "usage: $0 [build] | [version build] | --sync"
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
