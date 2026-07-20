#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 VERSION (for example 1.0.0)" >&2
  exit 64
fi

VERSION="${1#v}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_ROOT="${ROOT_DIR}/.build/community-release"
DERIVED_DATA="${RELEASE_ROOT}/DerivedData"
STAGING="${RELEASE_ROOT}/dmg-root"
DIST_DIR="${ROOT_DIR}/dist"
APP_PATH="${DERIVED_DATA}/Build/Products/Release/LoopKit.app"
HELPER_PATH="${APP_PATH}/Contents/Resources/loopkitd"
DMG_NAME="LoopKit-${VERSION}-Community.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
CHECKSUM_PATH="${DMG_PATH}.sha256"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "version must be MAJOR.MINOR.PATCH" >&2
  exit 1
}
[[ "$RELEASE_ROOT" == "${ROOT_DIR}/.build/community-release" ]] || {
  echo "unsafe release path" >&2
  exit 1
}

project_version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "${ROOT_DIR}/macos/ControlApp/project.yml" | sort -u)"
[[ "$project_version" == "$VERSION" ]] || {
  echo "release version $VERSION does not match project MARKETING_VERSION $project_version" >&2
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
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=LOOPKIT_COMMUNITY \
  -quiet \
  build

[[ -x "$HELPER_PATH" ]] || { echo "embedded helper missing" >&2; exit 1; }

# Ad-hoc signing gives the app and helper stable local code identifiers for
# authenticated XPC. It does not make Apple or Gatekeeper trust the artifact.
/usr/bin/codesign \
  --force --options runtime \
  --identifier com.twoplustwoone.LoopKit.agent \
  --sign - \
  "$HELPER_PATH"

/usr/bin/codesign \
  --force --options runtime \
  --identifier com.twoplustwoone.LoopKit \
  --sign - \
  "$APP_PATH"

"${ROOT_DIR}/scripts/validate_community_release.sh" "$APP_PATH"

mkdir -p "$STAGING"
/usr/bin/ditto "$APP_PATH" "${STAGING}/LoopKit.app"
/bin/ln -s /Applications "${STAGING}/Applications"
/usr/bin/hdiutil create \
  -volname "LoopKit Community" \
  -srcfolder "$STAGING" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

"${ROOT_DIR}/scripts/validate_community_release.sh" "$APP_PATH" "$DMG_PATH"
(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$DMG_NAME" >"$(basename "$CHECKSUM_PATH")"
)

echo "Community release artifacts (ad-hoc signed, not notarized):"
echo "  $DMG_PATH"
echo "  $CHECKSUM_PATH"
