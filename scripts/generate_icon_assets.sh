#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
icon_source="${repo_root}/design/icon/LoopKitIcon.svg"
menu_source="${repo_root}/design/icon/LoopKitMenuTemplate.svg"
renderer="${repo_root}/scripts/render_svg.swift"
catalog="${repo_root}/macos/ControlApp/Resources/Assets.xcassets"
appicon="${catalog}/AppIcon.appiconset"
menu="${catalog}/LoopKitMenuTemplate.imageset"

mkdir -p "${appicon}" "${menu}"

render() {
  /usr/bin/xcrun swift "${renderer}" "$1" "$2" "$3" "$4"
}

render "${icon_source}" "${appicon}/icon_16x16.png" 16 opaque
render "${icon_source}" "${appicon}/icon_16x16@2x.png" 32 opaque
render "${icon_source}" "${appicon}/icon_32x32.png" 32 opaque
render "${icon_source}" "${appicon}/icon_32x32@2x.png" 64 opaque
render "${icon_source}" "${appicon}/icon_128x128.png" 128 opaque
render "${icon_source}" "${appicon}/icon_128x128@2x.png" 256 opaque
render "${icon_source}" "${appicon}/icon_256x256.png" 256 opaque
render "${icon_source}" "${appicon}/icon_256x256@2x.png" 512 opaque
render "${icon_source}" "${appicon}/icon_512x512.png" 512 opaque
render "${icon_source}" "${appicon}/icon_512x512@2x.png" 1024 opaque
render "${menu_source}" "${menu}/LoopKitMenuTemplate.png" 18 alpha
render "${menu_source}" "${menu}/LoopKitMenuTemplate@2x.png" 36 alpha

echo "Generated LoopKit icon assets in ${catalog}"
