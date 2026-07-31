# agents.md

This file provides guidance to AI Coding Agents when working with code in this repository.

## What this is

LoopKit is a self-hosted macOS loopback stack for Discord-style sessions. The ControlApp and its app-owned XPC audio service share local SwiftPM modules; the service captures app/microphone audio, mixes it with the C++ engine, and writes the Broadcast mix to BlackHole 2ch. Target platform is macOS 14.2+.

## Development workflow

- Never develop on or push commits directly to `main`.
- Start each change on a focused branch created from an up-to-date `main`, and open a pull request targeting `main`.
- Keep `main` releasable. Successful `ci` for the current `main` commit automatically builds and publishes a Community DMG; superseded runs must not replace the latest release.
- Do not create or push version tags manually. The release workflow creates the tag only after the DMG has built and passed validation.
- Let pull-request CI pass before merging. Draft or incomplete work must remain on its branch.

## Build / test

Engine (pure C++, CMake, runs unit tests):

```bash
cmake -S engine -B /tmp/loopkit-engine-build
cmake --build /tmp/loopkit-engine-build
ctest --test-dir /tmp/loopkit-engine-build --output-on-failure
# single test binaries:
/tmp/loopkit-engine-build/loopkit_engine_tests
/tmp/loopkit-engine-build/loopkit_resampler_tests
```

Swift modules and hardware-independent DSP/scene tests:

```bash
swift test
```

Offline WAVE DSP runner:

```bash
swift run loopkit_offline_dsp app.wav output.wav --mic-input mic.wav --app-gain 0.8
```

Full macOS stack (embedded XPC audio service + SwiftUI app) — requires `xcodegen`, `xcodebuild`, `cmake`, and `ctest`. BlackHole is an external prerequisite and is never installed or removed by these scripts:

```bash
./installer/install_local.sh    # builds/tests and installs the combined development app
./installer/uninstall_local.sh
```

Xcode projects are **generated** from `macos/*/project.yml` via xcodegen and are gitignored — do not edit `*.xcodeproj` directly. Edit `project.yml` and re-run `xcodegen generate --spec <path>/project.yml --project <path>`. To build one target without the full install flow:

```bash
xcodegen generate --spec macos/Daemon/project.yml --project macos/Daemon
xcodebuild -project macos/Daemon/LoopKit-Daemon.xcodeproj -scheme LoopKitDaemon -configuration Debug -derivedDataPath .build/macos/Daemon build
```

Loopback smoke-test tool (standalone SwiftPM):

```bash
swift run --package-path tools/loopkit_loopback_test loopkit_loopback_test
```

## Architecture (big picture)

The two LoopKit processes share the `LoopKitIPC` XPC contract. The daemon core reaches the C++ engine and CoreAudio adapters through local SwiftPM modules declared in the root `Package.swift`.

```
  ┌────────────────┐  XPC   ┌──────────────────────┐  AUHAL output   ┌──────────────┐
  │  ControlApp    │◀──────▶│ XPC audio service    │───────────────▶│ BlackHole 2ch│
  │  (SwiftUI)     │        │  Swift + engine C++  │                │ Discord input│
  └────────────────┘        └──────────────────────┘                └──────────────┘
                                     ▲       │
                  Process Tap + mic  │       │ monitor mix
                                     │       ▼
                              selected apps  physical output
```

1. **Engine (`engine/`, SwiftPM product `LoopKitEngine`)** — realtime C++17 mixer. Two sources (app, mic), each with gain/mute/solo/enabled, plus master gain, soft clip, peak/rms meters. Swift talks to its C API (`loopkit_c_api.h`) through module imports and Swift C++ interoperability; there is no bridging header.

2. **IPC (`macos/Shared/Sources/LoopKitIPC.swift`, SwiftPM product `LoopKitIPC`)** — sole source of truth for the XPC protocol, secure-coding DTOs, and `configureLoopKitXPCInterface`. Any protocol change must update both processes together; the initial handshake rejects incompatible versions.

3. **AudioCore (`macos/AudioCore/`, SwiftPM product `LoopKitAudioCore`)** — Objective-C++ hardware boundary containing Process Tap capture, microphone capture, and AUHAL output routing.

4. **Audio service (`macos/Daemon/` + `macos/DaemonCore/`)** — `LoopKitAudioService.xpc` is an app-owned, thin authenticated XPC shell; it runs while LoopKit is active (including menu-bar-only operation) and stops on explicit app quit. `LoopKitDaemonRuntime` owns:
   - All control state + scene persistence (`~/Library/Application Support/LoopKit/scenes/*.json`).
   - **Application capture**: `ProcessTapManager.mm` provides per-bundle-ID Process Tap capture with
     `CATapMuted` redirect-muted playback on macOS 14.2+. There is no implicit virtual-device capture
     adapter; `getStatus` reports `LKCaptureModeUnavailable` and a warning when selected apps cannot
     be tapped.
   - Monitor output (`AudioOutputRouter.mm`) with automatic failover to system default if the selected device disappears.
   - The DSP render loop, physical microphone input, BlackHole 2ch Broadcast adapter, and physical Monitor output.

5. **ControlApp (`macos/ControlApp/`)** — SwiftUI. `LoopKitDaemonClient.swift` connects to the app-owned service, `LoopKitViewModel.swift` polls `getStatus` / `subscribeMeters`, and `LoopKitLegacyAgentMigrator` uses `SMAppService` only to remove the previous LaunchAgent during upgrade. It imports `LoopKitIPC` and hardware-independent `LoopKitUI`, with no direct engine or hardware access. The foreground app owns microphone permission requests.

6. **SceneStore (`macos/DaemonCore/SceneStore.swift`)** — JSON persistence isolated from daemon lifecycle and hardware so it can be exercised by `swift test`.

## Things that bite

- **Editing Xcode projects by hand does nothing** — they're regenerated from `project.yml` on every `install_local.sh` run. Change the `.yml`.
- **C++ interoperability propagates** — executable targets importing `LoopKitDaemonCore` need `SWIFT_OBJC_INTEROP_MODE: objcxx` in XcodeGen settings.
- **Community releases are intentionally unnotarized** — `scripts/community_release.sh` ad-hoc signs universal artifacts. Successful CI on merged `main` commits triggers the default workflow, which builds first and then creates the tag and GitHub Release without Apple credentials. `scripts/release.sh` is the unused optional Developer ID path.
- **The raw helper is migration-only** — `Contents/Resources/loopkitd` and its LaunchAgent plist remain dormant for one migration release. Never register them on a fresh installation. If unregistering an old agent fails, block the XPC service to avoid two audio engines.
- **Privacy belongs to the foreground app** — request microphone access through `MicrophoneAuthorizationController`, then tell the service to refresh. Never request TCC permission from the service and never invoke `tccutil`.
- **Scene schema lives in `docs/ARCHITECTURE.md`** and in `LKXPCScene` — keep them in sync when adding fields.
- **Legacy XPC coding keys** still contain `discord` for rolling-restart compatibility; Swift-facing
  status properties use the domain term `broadcast`.
- Product identities are `com.twoplustwoone.LoopKit` and `com.twoplustwoone.LoopKit.agent`. The remaining `com.example` strings exist only for legacy-install cleanup and compatibility tests.
