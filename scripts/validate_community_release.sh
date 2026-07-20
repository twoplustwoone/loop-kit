#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 LoopKit.app [LoopKit-Community.dmg]" >&2
  exit 64
fi

APP_PATH="$1"
DMG_PATH="${2:-}"
HELPER_PATH="${APP_PATH}/Contents/Resources/loopkitd"
AGENT_PLIST="${APP_PATH}/Contents/Library/LaunchAgents/com.twoplustwoone.LoopKit.agent.plist"
APP_PLIST="${APP_PATH}/Contents/Info.plist"
APP_BINARY="${APP_PATH}/Contents/MacOS/LoopKit"

fail() { echo "[community release validation] $*" >&2; exit 1; }
check_equal() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }

[[ -d "$APP_PATH" ]] || fail "app not found: $APP_PATH"
[[ -x "$APP_BINARY" ]] || fail "app executable missing"
[[ -x "$HELPER_PATH" ]] || fail "embedded helper missing"
[[ -f "$AGENT_PLIST" ]] || fail "embedded LaunchAgent missing"

/usr/bin/lipo "$APP_BINARY" -verify_arch arm64 x86_64 || fail "app is not universal"
/usr/bin/lipo "$HELPER_PATH" -verify_arch arm64 x86_64 || fail "helper is not universal"

check_equal "$(plist_value "$APP_PLIST" CFBundleIdentifier)" "com.twoplustwoone.LoopKit"
check_equal "$(plist_value "$APP_PLIST" LSMinimumSystemVersion)" "14.2"
check_equal "$(plist_value "$AGENT_PLIST" Label)" "com.twoplustwoone.LoopKit.agent"
check_equal "$(plist_value "$AGENT_PLIST" BundleProgram)" "Contents/Resources/loopkitd"

helper_plist="$(/usr/bin/otool -v -s __TEXT __info_plist "$HELPER_PATH")"
grep -q "com.twoplustwoone.LoopKit.agent" <<<"$helper_plist" || fail "helper identifier metadata missing"
grep -q "NSMicrophoneUsageDescription" <<<"$helper_plist" || fail "helper microphone privacy metadata missing"
grep -q "NSAudioCaptureUsageDescription" <<<"$helper_plist" || fail "helper audio-capture privacy metadata missing"

[[ -f "${APP_PATH}/Contents/Resources/AppIcon.icns" ]] || fail "compiled app icon missing"

for icon in "$(dirname "$0")/../macos/ControlApp/Resources/Assets.xcassets/AppIcon.appiconset"/*.png; do
  [[ "$(/usr/bin/sips -g hasAlpha "$icon" | awk '/hasAlpha/ { print $2 }')" == "no" ]] \
    || fail "app icon contains alpha: $icon"
done

/usr/bin/codesign --verify --strict "$HELPER_PATH" || fail "helper signature invalid"
/usr/bin/codesign --verify --deep --strict "$APP_PATH" || fail "app signature invalid"

app_details="$(/usr/bin/codesign -dvvv "$APP_PATH" 2>&1)"
helper_details="$(/usr/bin/codesign -dvvv "$HELPER_PATH" 2>&1)"
grep -q '^Identifier=com.twoplustwoone.LoopKit$' <<<"$app_details" || fail "app signing identifier mismatch"
grep -q '^Identifier=com.twoplustwoone.LoopKit.agent$' <<<"$helper_details" || fail "helper signing identifier mismatch"
grep -q '^Signature=adhoc$' <<<"$app_details" || fail "app is not ad-hoc signed"
grep -q '^Signature=adhoc$' <<<"$helper_details" || fail "helper is not ad-hoc signed"
grep -q 'flags=.*runtime' <<<"$app_details" || fail "app hardened runtime missing"
grep -q 'flags=.*runtime' <<<"$helper_details" || fail "helper hardened runtime missing"

if [[ -n "$DMG_PATH" ]]; then
  [[ -f "$DMG_PATH" ]] || fail "DMG not found: $DMG_PATH"
  /usr/bin/hdiutil verify "$DMG_PATH" || fail "DMG verification failed"
fi

echo "Community release validation passed (Gatekeeper trust is intentionally not claimed)"
