#!/usr/bin/env bash
set -euo pipefail

# LoopKit local install.
# Flags:
#   --skip-tests   Skip the engine ctest run (faster iteration).
#   --verbose      Stream xcodebuild output instead of summarizing.
#   --help

SKIP_TESTS=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) SKIP_TESTS=1 ;;
    --verbose)    VERBOSE=1 ;;
    --help|-h)
      cat <<USAGE
Usage: $0 [--skip-tests] [--verbose]

Builds the LoopKit engine, daemon, and ControlApp. Ensures BlackHole 2ch
(the Discord-facing virtual audio device) is installed — downloads and runs
its notarized pkg if not. Installs:
  ~/Library/Application Support/LoopKit/bin/loopkitd
  ~/Library/LaunchAgents/com.example.LoopKit.loopkitd.plist
  /Applications/LoopKit.app

Restarts coreaudiod (requires sudo) and runs post-install verification.
USAGE
      exit 0 ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/macos"
ENGINE_BUILD_DIR="${ROOT_DIR}/.build/engine"
DAEMON_BUILD_DIR="${BUILD_DIR}/Daemon"
APP_BUILD_DIR="${BUILD_DIR}/ControlApp"

DAEMON_PRODUCT="${DAEMON_BUILD_DIR}/Build/Products/Debug/loopkitd"
APP_PRODUCT="${APP_BUILD_DIR}/Build/Products/Debug/ControlApp.app"

DAEMON_INSTALL_DIR="${HOME}/Library/Application Support/LoopKit/bin"
DAEMON_INSTALL_PATH="${DAEMON_INSTALL_DIR}/loopkitd"
LAUNCH_AGENT_LABEL="com.example.LoopKit.loopkitd"
LAUNCH_AGENT_PATH="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
APP_INSTALL_PATH="/Applications/LoopKit.app"
BLACKHOLE_DEVICE_NAME="BlackHole 2ch"
BLACKHOLE_PKG_URL="https://existential.audio/downloads/BlackHole2ch.pkg"
DAEMON_NEEDS_RESTART=0

step()    { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn()    { printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }
die()     { printf "\033[1;31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

run_xcodebuild() {
  if [[ "$VERBOSE" == "1" ]]; then
    xcodebuild "$@"
  else
    local log
    log="$(mktemp -t loopkit-xcodebuild)"
    if ! xcodebuild "$@" >"$log" 2>&1; then
      tail -40 "$log" >&2
      die "xcodebuild failed — see $log for full output"
    fi
  fi
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1 (install via 'brew install $2')"
}

generate_project() {
  local spec="$1"
  local project_dir="$2"
  xcodegen generate --spec "$spec" --project "$project_dir" >/dev/null
}

build_target() {
  local project="$1"
  local scheme="$2"
  local dst="$3"
  rm -rf "$dst"
  run_xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -derivedDataPath "$dst" \
    -quiet \
    build
}

blackhole_installed() {
  system_profiler SPAudioDataType 2>/dev/null | grep -q "$BLACKHOLE_DEVICE_NAME"
}

ensure_blackhole() {
  if blackhole_installed; then
    printf "  %s already installed\n" "$BLACKHOLE_DEVICE_NAME"
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    step "Installing BlackHole 2ch via Homebrew cask"
    if brew install --cask blackhole-2ch; then
      return 0
    fi
    warn "brew install failed; falling back to direct pkg install"
  fi

  step "Downloading BlackHole 2ch installer"
  local pkg
  pkg="$(mktemp -t BlackHole2ch).pkg"
  if ! curl -fsSL -o "$pkg" "$BLACKHOLE_PKG_URL"; then
    rm -f "$pkg"
    die "Failed to download BlackHole 2ch from ${BLACKHOLE_PKG_URL}.
Install it manually from https://existential.audio/ and rerun this script."
  fi

  step "Running BlackHole installer (requires sudo)"
  sudo installer -pkg "$pkg" -target /
  rm -f "$pkg"
}

restart_coreaudio() {
  if [[ -t 0 && -t 1 ]]; then
    sudo killall coreaudiod
    return
  fi

  if sudo -n killall coreaudiod 2>/dev/null; then
    return
  fi

  /usr/bin/osascript \
    -e 'do shell script "/usr/bin/killall coreaudiod" with administrator privileges'
}

restore_daemon_on_exit() {
  local status=$?
  if [[ "$status" -ne 0 && "$DAEMON_NEEDS_RESTART" == "1" ]]; then
    warn "Install interrupted after stopping the daemon; attempting to restore it"
    if launchctl bootstrap "gui/${UID}" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1; then
      launchctl enable "gui/${UID}/${LAUNCH_AGENT_LABEL}" || true
    else
      warn "Could not restore ${LAUNCH_AGENT_LABEL}; rerun the installer"
    fi
  fi
  trap - EXIT
  exit "$status"
}

trap restore_daemon_on_exit EXIT

install_launch_agent() {
  mkdir -p "$(dirname "$LAUNCH_AGENT_PATH")" "${HOME}/Library/Logs/LoopKit"
  cat >"$LAUNCH_AGENT_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${DAEMON_INSTALL_PATH}</string>
  </array>
  <key>MachServices</key>
  <dict>
    <key>${LAUNCH_AGENT_LABEL}</key>
    <true/>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/LoopKit/loopkitd.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/LoopKit/loopkitd.log</string>
</dict>
</plist>
PLIST
}

verify_install() {
  local failures=0

  step "Verifying BlackHole 2ch"
  sleep 2
  if blackhole_installed; then
    printf "  %s present in system audio devices\n" "$BLACKHOLE_DEVICE_NAME"
  else
    warn "$BLACKHOLE_DEVICE_NAME not found in system audio devices"
    failures=$((failures + 1))
  fi

  step "Verifying daemon launch agent"
  if launchctl print "gui/${UID}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1; then
    printf "  launch agent active\n"
  else
    warn "launch agent ${LAUNCH_AGENT_LABEL} is not active"
    failures=$((failures + 1))
  fi

  step "Verifying ControlApp"
  if [[ -d "$APP_INSTALL_PATH" ]]; then
    printf "  app present at %s\n" "$APP_INSTALL_PATH"
  else
    warn "ControlApp missing at $APP_INSTALL_PATH"
    failures=$((failures + 1))
  fi

  if [[ $failures -gt 0 ]]; then
    warn "$failures verification step(s) reported problems — see messages above."
    return 1
  fi
  return 0
}

## ---------- main ----------

step "Checking dependencies"
require_tool xcodegen mxcl/made/xcodegen
require_tool xcodebuild Xcode
require_tool cmake cmake
require_tool ctest cmake

if [[ "$SKIP_TESTS" == "0" ]]; then
  step "Building engine and running tests"
  cmake -S "${ROOT_DIR}/engine" -B "$ENGINE_BUILD_DIR" -Wno-dev >/dev/null
  cmake --build "$ENGINE_BUILD_DIR" >/dev/null
  ctest --test-dir "$ENGINE_BUILD_DIR" --output-on-failure
else
  step "Skipping engine tests (--skip-tests)"
  cmake -S "${ROOT_DIR}/engine" -B "$ENGINE_BUILD_DIR" -Wno-dev >/dev/null
  cmake --build "$ENGINE_BUILD_DIR" >/dev/null
fi

step "Generating Xcode projects"
generate_project "${ROOT_DIR}/macos/Daemon/project.yml" "${ROOT_DIR}/macos/Daemon"
generate_project "${ROOT_DIR}/macos/ControlApp/project.yml" "${ROOT_DIR}/macos/ControlApp"

step "Building daemon"
build_target "${ROOT_DIR}/macos/Daemon/LoopKit-Daemon.xcodeproj" "LoopKitDaemon" "$DAEMON_BUILD_DIR"

step "Building control app"
build_target "${ROOT_DIR}/macos/ControlApp/LoopKit-ControlApp.xcodeproj" "ControlApp" "$APP_BUILD_DIR"

step "Ensuring BlackHole 2ch is installed"
ensure_blackhole

step "Stopping existing daemon"
launchctl bootout "gui/${UID}" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1 || true
DAEMON_NEEDS_RESTART=1

step "Installing daemon"
mkdir -p "$DAEMON_INSTALL_DIR" "${HOME}/Library/Logs/LoopKit"
DAEMON_INSTALL_CANDIDATE="${DAEMON_INSTALL_PATH}.new"
cp "$DAEMON_PRODUCT" "$DAEMON_INSTALL_CANDIDATE"
chmod +x "$DAEMON_INSTALL_CANDIDATE"
codesign --verify --strict "$DAEMON_INSTALL_CANDIDATE"
mv -f "$DAEMON_INSTALL_CANDIDATE" "$DAEMON_INSTALL_PATH"

step "Installing launch agent"
install_launch_agent

step "Installing ControlApp to ${APP_INSTALL_PATH}"
[[ -d "$APP_PRODUCT" ]] || die "ControlApp product not found at ${APP_PRODUCT}"
rm -rf "$APP_INSTALL_PATH"
cp -R "$APP_PRODUCT" "$APP_INSTALL_PATH"

step "Restarting coreaudiod"
restart_coreaudio || die "Failed to restart coreaudiod"
sleep 1

step "Starting daemon"
launchctl bootstrap "gui/${UID}" "$LAUNCH_AGENT_PATH"
launchctl enable "gui/${UID}/${LAUNCH_AGENT_LABEL}"
DAEMON_NEEDS_RESTART=0

step "Post-install verification"
if ! verify_install; then
  warn "Install finished with warnings. LoopKit may still work — launch the ControlApp from /Applications."
else
  step "Done"
  printf "  ControlApp: %s (also runnable from Launchpad)\n" "$APP_INSTALL_PATH"
  printf "  Daemon log: %s\n" "${HOME}/Library/Logs/LoopKit/loopkitd.log"
  printf "  In Discord, set microphone input to: %s\n" "$BLACKHOLE_DEVICE_NAME"
fi
