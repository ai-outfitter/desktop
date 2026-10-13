#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/.derived-data/outfitter-app"
log="$root/.local/build.log"
mkdir -p "$root/.local"
if [[ "${1:-}" != "--no-build" ]]; then
  xcodebuild -project "$root/PiNative.xcodeproj" -scheme PiNative \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$derived" \
    PRODUCT_BUNDLE_IDENTIFIER=com.ai-outfitter.desktop.internal \
    CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1 || { tail -60 "$log"; exit 1; }
fi
app="$derived/Build/Products/Debug/PiNative.app"
/usr/bin/pkill -f "^${app}/Contents/MacOS/PiNative$" || true
/usr/bin/open -n --env "OUTFITTER_DESKTOP_CLI=${OUTFITTER_DESKTOP_CLI:-$root/scripts/outfitter-local}" \
  --env "OUTFITTER_DESKTOP_AGENT=${OUTFITTER_DESKTOP_AGENT:-desktop}" \
  --env "OUTFITTER_DESKTOP_STATE_DIRECTORY=$root/.local/outfitter-home" \
  --env "OUTFITTER_DESKTOP_ORIGIN=${OUTFITTER_DESKTOP_ORIGIN:-http://localhost:4481}" "$app"
printf 'Opened: %s\n' "$app"
