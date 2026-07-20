#!/usr/bin/env bash
set -euo pipefail

# Developer cleanup. BlackHole is always preserved because it is a separate
# product and may be used by other audio software.

KEEP_DATA=0
for arg in "$@"; do
  case "$arg" in
    --keep-data) KEEP_DATA=1 ;;
    --help|-h)
      echo "Usage: $0 [--keep-data]"
      echo "Removes the local LoopKit app/helper and legacy developer installation."
      echo "BlackHole is never removed."
      exit 0
      ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

APP_INSTALL_PATH="/Applications/LoopKit.app"
SUPPORT_DIR="${HOME}/Library/Application Support/LoopKit"
LEGACY_AGENT="${HOME}/Library/LaunchAgents/com.example.LoopKit.loopkitd.plist"
LEGACY_DAEMON="${SUPPORT_DIR}/bin/loopkitd"

step() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }

step "Stopping registered and legacy helpers"
launchctl bootout "gui/${UID}/com.twoplustwoone.LoopKit.agent" >/dev/null 2>&1 || true
launchctl bootout "gui/${UID}" "$LEGACY_AGENT" >/dev/null 2>&1 || true

step "Removing the development app and legacy loose helper"
rm -rf "$APP_INSTALL_PATH"
rm -f "$LEGACY_AGENT" "$LEGACY_DAEMON"

if [[ "$KEEP_DATA" == "0" ]]; then
  step "Removing LoopKit application state"
  rm -rf "$SUPPORT_DIR"
else
  step "Preserving LoopKit application state"
fi

step "Developer uninstall complete; BlackHole was preserved"
