#!/usr/bin/env bash
set -euo pipefail

# Developer-only local build/install. Public users install a notarized DMG.
# The app owns helper registration through SMAppService; this script never
# installs a loose daemon, writes a LaunchAgent, or downloads BlackHole.

SKIP_TESTS=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) SKIP_TESTS=1 ;;
    --verbose) VERBOSE=1 ;;
    --help|-h)
      echo "Usage: $0 [--skip-tests] [--verbose]"
      echo "Builds and copies LoopKit.app to /Applications for local development."
      echo "Launch LoopKit afterward and complete setup to register its embedded helper."
      exit 0
      ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_BUILD_DIR="${ROOT_DIR}/.build/engine"
APP_BUILD_DIR="${ROOT_DIR}/.build/macos/ControlApp"
APP_PRODUCT="${APP_BUILD_DIR}/Build/Products/Debug/LoopKit.app"
APP_INSTALL_PATH="/Applications/LoopKit.app"

step() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

run_xcodebuild() {
  if [[ "$VERBOSE" == "1" ]]; then
    xcodebuild "$@"
    return
  fi
  local log
  log="$(mktemp -t loopkit-xcodebuild)"
  if ! xcodebuild "$@" >"$log" 2>&1; then
    tail -60 "$log" >&2
    die "xcodebuild failed; full output is in $log"
  fi
}

step "Checking developer dependencies"
require_tool cmake
require_tool ctest
require_tool swift
require_tool xcodebuild
require_tool xcodegen

if [[ "$SKIP_TESTS" == "0" ]]; then
  step "Running C++ engine tests"
  cmake -S "${ROOT_DIR}/engine" -B "$ENGINE_BUILD_DIR" -Wno-dev
  cmake --build "$ENGINE_BUILD_DIR"
  ctest --test-dir "$ENGINE_BUILD_DIR" --output-on-failure

  step "Running Swift tests"
  swift test --package-path "$ROOT_DIR"
else
  step "Skipping tests (--skip-tests)"
fi

step "Generating the combined app/helper project"
xcodegen generate \
  --spec "${ROOT_DIR}/macos/ControlApp/project.yml" \
  --project "${ROOT_DIR}/macos/ControlApp"

step "Building LoopKit.app with its embedded helper"
run_xcodebuild \
  -project "${ROOT_DIR}/macos/ControlApp/LoopKit-ControlApp.xcodeproj" \
  -scheme ControlApp \
  -configuration Debug \
  -derivedDataPath "$APP_BUILD_DIR" \
  build

[[ -d "$APP_PRODUCT" ]] || die "app product not found at $APP_PRODUCT"
[[ -x "$APP_PRODUCT/Contents/Resources/loopkitd" ]] || die "embedded helper is missing"

step "Installing the development app"
rm -rf "$APP_INSTALL_PATH"
/usr/bin/ditto "$APP_PRODUCT" "$APP_INSTALL_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_INSTALL_PATH"

step "Developer install complete"
echo "Open ${APP_INSTALL_PATH} and follow first-run setup."
echo "LoopKit will register its embedded helper through macOS Login Items."
echo "BlackHole is intentionally separate: https://existential.audio/blackhole/"
