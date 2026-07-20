#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 VERSION (for example 1.0.0)" >&2
  exit 64
fi

VERSION="${1#v}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_ROOT="${ROOT_DIR}/.build/release"
DERIVED_DATA="${RELEASE_ROOT}/DerivedData"
STAGING="${RELEASE_ROOT}/dmg-root"
DIST_DIR="${ROOT_DIR}/dist"
APP_PATH="${DERIVED_DATA}/Build/Products/Release/LoopKit.app"
HELPER_PATH="${APP_PATH}/Contents/Resources/loopkitd"
DMG_PATH="${DIST_DIR}/LoopKit-${VERSION}.dmg"
CHECKSUM_PATH="${DMG_PATH}.sha256"

required=(
  DEVELOPER_ID_APPLICATION
  DEVELOPMENT_TEAM
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_ISSUER_ID
  APP_STORE_CONNECT_API_KEY_PATH
)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { echo "missing required environment variable: $name" >&2; exit 1; }
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be MAJOR.MINOR.PATCH" >&2; exit 1; }
[[ "$RELEASE_ROOT" == "${ROOT_DIR}/.build/release" ]] || { echo "unsafe release path" >&2; exit 1; }

project_version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "${ROOT_DIR}/macos/ControlApp/project.yml" | sort -u)"
[[ "$project_version" == "$VERSION" ]] || {
  echo "tag version $VERSION does not match project MARKETING_VERSION $project_version" >&2
  exit 1
}
if [[ -n "${GITHUB_REF_NAME:-}" ]]; then
  [[ "$GITHUB_REF_NAME" == "v${VERSION}" ]] || { echo "tag must be v${VERSION}" >&2; exit 1; }
fi

rm -rf "$RELEASE_ROOT"
mkdir -p "$RELEASE_ROOT" "$DIST_DIR"

cmake -S "${ROOT_DIR}/engine" -B "${RELEASE_ROOT}/engine" -Wno-dev
cmake --build "${RELEASE_ROOT}/engine" --parallel
ctest --test-dir "${RELEASE_ROOT}/engine" --output-on-failure
swift test --package-path "$ROOT_DIR"

xcodegen generate \
  --spec "${ROOT_DIR}/macos/ControlApp/project.yml" \
  --project "${ROOT_DIR}/macos/ControlApp"

xcodebuild \
  -project "${ROOT_DIR}/macos/ControlApp/LoopKit-ControlApp.xcodeproj" \
  -scheme ControlApp \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  build

[[ -x "$HELPER_PATH" ]] || { echo "embedded helper missing" >&2; exit 1; }

/usr/bin/codesign \
  --force --options runtime --timestamp \
  --identifier com.twoplustwoone.LoopKit.agent \
  --sign "$DEVELOPER_ID_APPLICATION" \
  "$HELPER_PATH"

/usr/bin/codesign \
  --force --options runtime --timestamp \
  --identifier com.twoplustwoone.LoopKit \
  --sign "$DEVELOPER_ID_APPLICATION" \
  "$APP_PATH"

"${ROOT_DIR}/scripts/validate_release.sh" "$APP_PATH"

mkdir -p "$STAGING"
/usr/bin/ditto "$APP_PATH" "${STAGING}/LoopKit.app"
/bin/ln -s /Applications "${STAGING}/Applications"
/usr/bin/hdiutil create \
  -volname LoopKit \
  -srcfolder "$STAGING" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

/usr/bin/codesign \
  --force --options runtime --timestamp \
  --sign "$DEVELOPER_ID_APPLICATION" \
  "$DMG_PATH"

/usr/bin/xcrun notarytool submit "$DMG_PATH" \
  --key "$APP_STORE_CONNECT_API_KEY_PATH" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait
/usr/bin/xcrun stapler staple "$DMG_PATH"

"${ROOT_DIR}/scripts/validate_release.sh" "$APP_PATH" "$DMG_PATH"
/usr/bin/shasum -a 256 "$DMG_PATH" >"$CHECKSUM_PATH"

echo "Release artifacts:"
echo "  $DMG_PATH"
echo "  $CHECKSUM_PATH"
