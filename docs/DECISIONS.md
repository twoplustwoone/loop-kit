# Architecture decisions

## BlackHole remains an external dependency

LoopKit writes its Broadcast mix to BlackHole 2ch, but does not redistribute, download, install, update, or remove BlackHole. The first-run setup links to the official project. This avoids silently modifying a shared system audio component and respects BlackHole's independent release and licensing lifecycle.

The active BlackHole device can never be selected as LoopKit's Monitor output. Enforcing this in both the daemon and UI prevents a direct feedback loop.

## The helper is embedded and app-managed

The helper executable is embedded at `LoopKit.app/Contents/Resources/loopkitd`. Its LaunchAgent plist is embedded under `Contents/Library/LaunchAgents` and uses `BundleProgram`. `LoopKitHelperManager`, backed by `SMAppService`, is the only application interface for registration, repair, approval status, and removal.

The helper is signed before the enclosing app. Release XPC connections require the exact peer identifier, Apple signing anchor, and matching Team ID. Ad-hoc Debug builds use identifier-only requirements so local development remains possible.

## The code calls it a Routing Graph

Internal types and documentation use **Routing Graph**. The dashboard deliberately keeps **ROUTING PATCHBAY** as the visible product copy because it clearly communicates the interaction to musicians and streamers.
