#!/usr/bin/env bash
# Run Gitchat on a second (or any) iOS simulator.
#
# Usage:
#   ./scripts/run-sim.sh              # interactive picker
#   ./scripts/run-sim.sh "iPhone 17"  # direct
#   ./scripts/run-sim.sh --list       # just list available devices
#   ./scripts/run-sim.sh --build      # force a fresh build first

set -euo pipefail

SCHEME="GitchatIOS"
PROJECT="GitchatIOS.xcodeproj"
BUNDLE_ID="chat.git"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}!!${NC}  $*"; }
die()   { echo -e "${RED}xx${NC}  $*" >&2; exit 1; }

# --- Parse args ---
FORCE_BUILD=0
TARGET_DEVICE=""
for arg in "$@"; do
    case "$arg" in
        --list)
            xcrun simctl list devices available | grep -E "iPhone|iPad" | grep -v unavailable
            exit 0
            ;;
        --build)
            FORCE_BUILD=1
            ;;
        -h|--help)
            sed -n '2,10p' "$0"
            exit 0
            ;;
        *)
            TARGET_DEVICE="$arg"
            ;;
    esac
done

# --- Locate the built .app ---
find_app() {
    find "$HOME/Library/Developer/Xcode/DerivedData" \
        -name "*.app" \
        -path "*Debug-iphonesimulator*" \
        -path "*GitchatIOS*" \
        -not -path "*/Intermediates.noindex/*" \
        -print0 2>/dev/null \
        | xargs -0 ls -td 2>/dev/null \
        | head -1
}

APP_PATH="$(find_app || true)"

if [[ -z "$APP_PATH" || "$FORCE_BUILD" -eq 1 ]]; then
    info "Building $SCHEME for simulator (this may take a while)..."
    cd "$(dirname "$0")/.."
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' \
        build \
        | (command -v xcpretty >/dev/null && xcpretty || cat) \
        || die "xcodebuild failed"
    APP_PATH="$(find_app || true)"
fi

[[ -z "$APP_PATH" ]] && die "Cannot locate built .app. Try: $0 --build"
info "Using app: $APP_PATH"

# --- Pick a simulator ---
pick_device() {
    local rows=()
    while IFS= read -r line; do
        rows+=("$line")
    done < <(xcrun simctl list devices available \
        | grep -E "iPhone|iPad" \
        | grep -vE "unavailable" \
        | sed -E 's/^ *//')

    [[ ${#rows[@]} -eq 0 ]] && die "No simulators found."

    if command -v fzf >/dev/null; then
        local choice
        choice="$(printf '%s\n' "${rows[@]}" | fzf \
            --height=40% --reverse --border \
            --prompt="Pick a simulator > " \
            --header="↑/↓ navigate · Enter select · Esc cancel" \
            --preview-window=hidden)"
        [[ -z "$choice" ]] && die "Cancelled."
        TARGET_DEVICE="$(echo "$choice" | sed -E 's/ *\(.*//')"
    else
        warn "fzf not installed — using numbered picker. Install with: brew install fzf"
        info "Available iPhone/iPad simulators:"
        local i=1
        for row in "${rows[@]}"; do
            local flag=""
            [[ "$row" == *"(Booted)"* ]] && flag=" [BOOTED]"
            printf "  %2d) %s%s\n" "$i" "$row" "$flag"
            i=$((i+1))
        done
        echo
        read -rp "Pick a device (number), or type name: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local idx=$((choice-1))
            [[ $idx -lt 0 || $idx -ge ${#rows[@]} ]] && die "Invalid index"
            TARGET_DEVICE="$(echo "${rows[$idx]}" | sed -E 's/ *\(.*//')"
        else
            TARGET_DEVICE="$choice"
        fi
    fi
}

[[ -z "$TARGET_DEVICE" ]] && pick_device

# --- Boot (idempotent) ---
info "Booting \"$TARGET_DEVICE\"..."
if xcrun simctl boot "$TARGET_DEVICE" 2>/dev/null; then
    info "Booted."
else
    STATE="$(xcrun simctl list devices | grep -F "$TARGET_DEVICE" | head -1 || true)"
    if [[ "$STATE" == *"(Booted)"* ]]; then
        info "Already booted."
    else
        die "Could not boot \"$TARGET_DEVICE\". Is the name correct? Try: $0 --list"
    fi
fi

open -a Simulator

# --- Install ---
info "Installing app..."
xcrun simctl install "$TARGET_DEVICE" "$APP_PATH"

# --- Launch ---
info "Launching $BUNDLE_ID..."
xcrun simctl launch "$TARGET_DEVICE" "$BUNDLE_ID"

info "Done. App running on \"$TARGET_DEVICE\"."
