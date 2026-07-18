#!/usr/bin/env bash
set -euo pipefail

# Removes the local LoopKit install.
# Flags:
#   --keep-data          Preserve ~/Library/Application Support/LoopKit (scenes, config).
#   --keep-logs          Preserve ~/Library/Logs/LoopKit.
#   --remove-blackhole   Also uninstall BlackHole 2ch (not removed by default).

KEEP_DATA=0
KEEP_LOGS=0
REMOVE_BLACKHOLE=0
for arg in "$@"; do
  case "$arg" in
    --keep-data) KEEP_DATA=1 ;;
    --keep-logs) KEEP_LOGS=1 ;;
    --remove-blackhole) REMOVE_BLACKHOLE=1 ;;
    --help|-h)
      cat <<USAGE
Usage: $0 [--keep-data] [--keep-logs] [--remove-blackhole]

Removes:
  ~/Library/Application Support/LoopKit/bin/loopkitd
  ~/Library/LaunchAgents/com.example.LoopKit.loopkitd.plist
  /Applications/LoopKit.app

Also removes unless --keep-data:
  ~/Library/Application Support/LoopKit   (scenes, derived state)

Also removes unless --keep-logs:
  ~/Library/Logs/LoopKit

BlackHole 2ch (the virtual audio device LoopKit writes into) is left alone by
default because other apps on your machine may depend on it. Pass
--remove-blackhole to also uninstall it.
USAGE
      exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

DAEMON_DIR="${HOME}/Library/Application Support/LoopKit"
DAEMON_INSTALL_PATH="${DAEMON_DIR}/bin/loopkitd"
LAUNCH_AGENT_LABEL="com.example.LoopKit.loopkitd"
LAUNCH_AGENT_PATH="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
APP_INSTALL_PATH="/Applications/LoopKit.app"
LOG_DIR="${HOME}/Library/Logs/LoopKit"

step() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }

step "Unloading launch agent"
launchctl bootout "gui/${UID}" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1 || true

step "Removing launch agent and daemon binary"
rm -f "$LAUNCH_AGENT_PATH"
rm -f "$DAEMON_INSTALL_PATH"

step "Removing ControlApp"
rm -rf "$APP_INSTALL_PATH"

if [[ "$KEEP_DATA" == "0" ]]; then
  step "Removing application support directory ($DAEMON_DIR)"
  rm -rf "$DAEMON_DIR"
else
  step "Preserving $DAEMON_DIR (--keep-data)"
fi

if [[ "$KEEP_LOGS" == "0" ]]; then
  step "Removing logs ($LOG_DIR)"
  rm -rf "$LOG_DIR"
else
  step "Preserving $LOG_DIR (--keep-logs)"
fi

if [[ "$REMOVE_BLACKHOLE" == "1" ]]; then
  step "Uninstalling BlackHole 2ch"
  if command -v brew >/dev/null 2>&1 && brew list --cask blackhole-2ch >/dev/null 2>&1; then
    brew uninstall --cask blackhole-2ch || warn "brew uninstall returned an error"
  else
    # Find and run the uninstaller script shipped with the BlackHole pkg.
    uninstaller="$(find "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver" -name 'uninstall*' 2>/dev/null | head -1 || true)"
    if [[ -n "$uninstaller" ]]; then
      sudo "$uninstaller"
    else
      warn "BlackHole 2ch uninstaller not found. Remove manually via: sudo rm -rf /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"
    fi
  fi
fi

step "Restarting coreaudiod"
sudo killall coreaudiod || true

step "Uninstall complete"
