# Architecture decisions

## BlackHole remains an external dependency

LoopKit writes its Broadcast mix to BlackHole 2ch, but does not redistribute, download, install, update, or remove BlackHole. The first-run setup links to the official project. This avoids silently modifying a shared system audio component and respects BlackHole's independent release and licensing lifecycle.

The active BlackHole device can never be selected as LoopKit's Monitor output. Enforcing this in both the daemon and UI prevents a direct feedback loop.

## The audio runtime is an app-owned XPC service

The active runtime is embedded at `LoopKit.app/Contents/XPCServices/LoopKitAudioService.xpc`. ControlApp connects with `NSXPCConnection(serviceName:)`; the service accepts connections with `NSXPCListener.service()`. It stays alive when the dashboard closes because LoopKit remains a menu-bar app, and stops when the user explicitly quits LoopKit. Fresh installations do not create a Login Item or register a LaunchAgent.

For one migration release, the previous raw helper and LaunchAgent plist remain dormant inside the app. Upgrade startup uses `SMAppService` only to unregister that old agent. If removal fails, the new service is blocked and setup offers retry and Login Items settings, preventing two engines from controlling the same devices.

The XPC service and transitional helper are signed before the enclosing app. Community and Debug builds are ad-hoc signed and use identifier-only XPC requirements. Optional Developer ID releases require the exact peer identifier, Apple signing anchor, and matching Team ID.

## The foreground app owns microphone consent

ControlApp requests microphone authorization through AVFoundation, while the embedded service only refreshes authorization state and starts or stops capture. This makes fresh privacy prompts and Settings rows identify **LoopKit** with its icon. Microphone capture remains optional. Community builds may need approval again after an update because ad-hoc code identity is not guaranteed to persist; setup treats that as a recoverable permission state.

## Community distribution is the default

Tagged builds publish a universal ad-hoc-signed Community DMG plus SHA-256 checksum without Apple credentials. This intentionally accepts a one-time **Privacy & Security → Open Anyway** step instead of requiring a paid Apple Developer membership. The release and documentation must never claim that Community artifacts are notarized, Apple-scanned, or backed by a verified publisher identity.

The Developer ID/notarization scripts remain optional, but the default GitHub workflow does not invoke them or require their secrets.

## The code calls it a Routing Graph

Internal types and documentation use **Routing Graph**. The dashboard deliberately keeps **ROUTING PATCHBAY** as the visible product copy because it clearly communicates the interaction to musicians and streamers.
