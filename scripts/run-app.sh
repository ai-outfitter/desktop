#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="${PROJECT_ROOT}/PiNative.xcodeproj"
SCHEME="PiNative"
CONFIGURATION="Debug"
DERIVED_DATA="${PROJECT_ROOT}/.derived-data/run-app"
RELAUNCH_LOG_FILE="/tmp/pinative-run-app.log"
BUILD_LOG_FILE="/tmp/pinative-run-app-build.log"
CLEAN=0
RUN_TESTS=0
LAUNCH=1
SIDECAR=0

usage() {
  cat <<'EOF'
Usage: scripts/run-app.sh [--clean] [--test] [--sidecar] [--no-launch]

Builds PiNative into a repo-local DerivedData directory, then relaunches the
latest Debug app. The relaunch is detached so it still completes if invoked
from a PiNative-hosted Pi session.

Options:
  --clean      Remove the run-app DerivedData directory before building.
  --test       Run the unit-only PiNative test action before launching; UI tests are excluded.
  --sidecar    Launch a second, isolated PiNative instance alongside the
               running app instead of restarting it. Never kills any running
               PiNative, so it is safe to run from a Pi session hosted by
               PiNative. Uses its own state directory
               (.local/outfitter-home-sidecar) and reuses the host's bundled
               Outfitter CLI.
  --no-launch  Build only; do not restart/open the app.
  -h, --help   Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=1 ;;
    --test) RUN_TESTS=1 ;;
    --sidecar) SIDECAR=1 ;;
    --no-launch) LAUNCH=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

cd "$PROJECT_ROOT"

if [[ $CLEAN -eq 1 ]]; then
  rm -rf "$DERIVED_DATA"
fi

build_args=(
  -project "$PROJECT_FILE"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA"
)

if [[ $RUN_TESTS -eq 1 ]]; then
  if ! scripts/test-unit.sh; then
    echo "Unit tests failed. Log: /tmp/pinative-unit-tests.log" >&2
    exit 1
  fi
fi

# Unit tests use separate DerivedData; always build the app that this script
# will launch so --test cannot accidentally open a stale run-app build.
echo "Building PiNative…"
if ! xcodebuild "${build_args[@]}" build >"$BUILD_LOG_FILE" 2>&1; then
  echo "Build failed. Log: $BUILD_LOG_FILE" >&2
  tail -80 "$BUILD_LOG_FILE" >&2 || true
  exit 1
fi

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/PiNative.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at: $APP_PATH" >&2
  exit 1
fi

if [[ $LAUNCH -eq 0 ]]; then
  echo "Built: $APP_PATH"
  exit 0
fi

if [[ $SIDECAR -eq 1 ]]; then
  # Agent-safe launch: open a second, isolated instance and leave every
  # running PiNative (including the one hosting this Pi session) untouched.
  # The app resolves the bundled/installed Outfitter CLI itself, so the sidecar
  # only overrides the one thing it needs: an isolated state directory.
  sidecar_state="${OUTFITTER_SIDECAR_STATE_DIRECTORY:-$PROJECT_ROOT/.local/outfitter-home-sidecar}"
  if command -v node >/dev/null 2>&1; then
    OUTFITTER_DESKTOP_STATE_DIRECTORY="$sidecar_state" \
      node "$PROJECT_ROOT/scripts/configure-outfitter-state.mjs"
  fi
  /usr/bin/open -n \
    --env "OUTFITTER_DESKTOP_STATE_DIRECTORY=$sidecar_state" \
    "$APP_PATH" --args -ApplePersistenceIgnoreState YES
  echo "Sidecar instance opened: $APP_PATH"
  echo "Sidecar state directory: $sidecar_state"
  echo "No running PiNative was restarted."
  exit 0
fi

# Detach the restart so /run can be used from inside PiNative without the
# parent process dying before the app is relaunched.
nohup /bin/bash -c '
  app_path="$1"
  sleep 0.4
  /usr/bin/pkill -x PiNative >/dev/null 2>&1 || true
  /usr/bin/open -n "$app_path"
  sleep 0.8
  /usr/bin/osascript -e "tell application \"PiNative\" to activate" >/dev/null 2>&1 || true
' -- "$APP_PATH" >"$RELAUNCH_LOG_FILE" 2>&1 &

echo "Built: $APP_PATH"
echo "Build log: $BUILD_LOG_FILE"
echo "Relaunching and focusing PiNative (relaunch log: $RELAUNCH_LOG_FILE)"
