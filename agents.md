# agents.md

This file provides guidance to AI Coding Agents when working with code in this repository.

## What this is

LoopKit is a self-hosted macOS loopback stack for Discord-style sessions. The ControlApp and `loopkitd` daemon share local SwiftPM modules; the daemon captures app/microphone audio, mixes it with the C++ engine, and writes the Broadcast mix to BlackHole 2ch. Target platform is macOS 14+ (Process Tap capture requires 14.2+).

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
swift run loopkit_offline_dsp input.wav output.wav --gain 0.8
```

Full macOS stack (daemon + SwiftUI app + BlackHole 2ch) — requires `xcodegen`, `xcodebuild`, `cmake`, and `ctest`; first-time BlackHole installation may require `sudo`:

```bash
./installer/install_local.sh    # builds/tests, generates Xcode projects, builds and installs daemon/app
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
  │  ControlApp    │◀──────▶│  loopkitd (daemon)   │───────────────▶│ BlackHole 2ch│
  │  (SwiftUI)     │        │  Swift + engine C++  │                │ Discord input│
  └────────────────┘        └──────────────────────┘                └──────────────┘
                                     ▲       │
                  Process Tap + mic  │       │ monitor mix
                                     │       ▼
                              selected apps  physical output
```

1. **Engine (`engine/`, SwiftPM product `LoopKitEngine`)** — realtime C++17 mixer. Two sources (app, mic), each with gain/mute/solo/enabled, plus master gain, soft clip, peak/rms meters. Swift talks to its C API (`loopkit_c_api.h`) through module imports and Swift C++ interoperability; there is no bridging header.

2. **IPC (`macos/Shared/Sources/LoopKitIPC.swift`, SwiftPM product `LoopKitIPC`)** — sole source of truth for the XPC protocol, secure-coding DTOs, and `configureLoopKitXPCInterface`. Any protocol change must update both processes together; there is no version negotiation.

3. **AudioCore (`macos/AudioCore/`, SwiftPM product `LoopKitAudioCore`)** — Objective-C++ hardware boundary containing Process Tap capture, microphone capture, and AUHAL output routing.

4. **Daemon (`macos/Daemon/` + `macos/DaemonCore/`)** — the executable is a thin mach-service shell; `LoopKitDaemonCore` owns:
   - All control state + scene persistence (`~/Library/Application Support/LoopKit/scenes/*.json`).
   - **Application capture**: `ProcessTapManager.mm` provides per-bundle-ID Process Tap capture with
     `CATapMuted` redirect-muted playback on macOS 14.2+. There is no implicit virtual-device capture
     adapter; `getStatus` reports `LKCaptureModeUnavailable` and a warning when selected apps cannot
     be tapped.
   - Monitor output (`AudioOutputRouter.mm`) with automatic failover to system default if the selected device disappears.
   - The DSP render loop, physical microphone input, BlackHole 2ch Broadcast adapter, and physical Monitor output.

5. **ControlApp (`macos/ControlApp/`)** — SwiftUI. `LoopKitDaemonClient.swift` is the XPC client, `LoopKitViewModel.swift` polls `getStatus` / `subscribeMeters`. It imports only `LoopKitIPC` and has no direct engine or hardware access.

6. **SceneStore (`macos/DaemonCore/SceneStore.swift`)** — JSON persistence isolated from daemon lifecycle and hardware so it can be exercised by `swift test`.

## Things that bite

- **Editing Xcode projects by hand does nothing** — they're regenerated from `project.yml` on every `install_local.sh` run. Change the `.yml`.
- **C++ interoperability propagates** — executable targets importing `LoopKitDaemonCore` need `SWIFT_OBJC_INTEROP_MODE: objcxx` in XcodeGen settings.
- **Unsigned personal workflow** — the targets use `CODE_SIGN_IDENTITY: "-"`. This is intentional; do not add signing identities without being asked.
- **Scene schema lives in `docs/ARCHITECTURE.md`** and in `LKXPCScene` — keep them in sync when adding fields.
- **Legacy XPC coding keys** still contain `discord` for rolling-restart compatibility; Swift-facing
  status properties use the domain term `broadcast`.
- The `com.example.LoopKit.*` bundle IDs and mach service name are hardcoded across `project.yml`, `LoopKitIPC.swift`, and the launch agent plist — renaming requires touching all three.
