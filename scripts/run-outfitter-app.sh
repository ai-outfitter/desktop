#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/.derived-data/outfitter-app"
log="$root/.local/build.log"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
mkdir -p "$root/.local"
state="${OUTFITTER_DESKTOP_STATE_DIRECTORY:-$root/.local/outfitter-home}"
export OUTFITTER_DESKTOP_STATE_DIRECTORY="$state"
cli="${OUTFITTER_DESKTOP_CLI:-$root/.local/cli/bin/outfitter}"
if [[ ! -x "$cli" ]]; then cli="${OUTFITTER_DESKTOP_CLI:-$(command -v outfitter || true)}"; fi
if [[ -z "$cli" || ! -x "$cli" ]]; then
  echo 'Install the released CLI with npm install -g @ai-outfitter/outfitter, or set OUTFITTER_DESKTOP_CLI to its absolute executable path.' >&2
  exit 1
fi
cli="$(cd "$(dirname "$cli")" && pwd)/$(basename "$cli")"
node "$root/scripts/configure-outfitter-state.mjs" "$("$cli" --version)"
if [[ "${1:-}" != "--no-build" ]]; then
  xcodebuild -project "$root/PiNative.xcodeproj" -scheme PiNative \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$derived" \
    PRODUCT_BUNDLE_IDENTIFIER=com.ai-outfitter.desktop.internal \
    CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1 || { tail -60 "$log"; exit 1; }
fi
app="$derived/Build/Products/Debug/PiNative.app"
/usr/bin/pkill -f "^${app}/Contents/MacOS/PiNative$" || true
/usr/bin/open -n --env "OUTFITTER_DESKTOP_CLI=${cli}" \
  --env "OUTFITTER_DESKTOP_AGENT=${OUTFITTER_DESKTOP_AGENT:-desktop}" \
  --env "OUTFITTER_DESKTOP_STATE_DIRECTORY=$state" \
  --env "OUTFITTER_USER_HOME=$state" "$app"
printf 'Opened: %s\n' "$app"
