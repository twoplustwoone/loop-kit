# LoopKit

LoopKit is a self-hosted macOS loopback tool for Discord-style sessions. It is structured like a
Loopback-style stack:

- `engine/`: realtime C++ mixer core and C API, exposed to Swift as `LoopKitEngine`.
- `macos/AudioCore/`: Objective-C++ Process Tap, microphone input, and audio output adapters.
- `macos/DaemonCore/`: testable Swift daemon state, routing, DSP, and scene persistence logic.
- `macos/Daemon/`: thin `loopkitd` mach-service entry point.
- `macos/Shared/Sources/`: the `LoopKitIPC` XPC protocol and secure-coding DTO module.
- `macos/LoopKitUI/`: reusable Obsidian Studio tokens, meters, faders, and Source strips.
- `macos/ControlApp/`: SwiftUI mixer UI for gains, mute/solo, monitor output, and scene save/load.
- `installer/`: developer-only local build/install scripts.

## What is implemented

- C++ mixer engine with:
  - app + mic sources,
  - per-source gain/mute/solo/enabled,
  - master gain, continuous saturation, and pre-saturation clip flags,
  - peak/rms meters with one-second clip hold in the UI.
- C API for engine control (`engine/include/loopkit_c_api.h`).
- Engine and resampler unit tests (`cmake` + `ctest`).
- Hardware-independent Swift tests for offline DSP mixing, WAVE I/O, Monitor failover policy,
  IPC secure coding, gain boundaries, routing, and scene JSON persistence.
- Offline WAVE runner (`loopkit_offline_dsp`) for processing fixtures without CoreAudio.
- `loopkitd` XPC service surface:
  - `SetMasterGain`, `SetSourceParams`, `SetMuteSolo`, `SetMonitorDevice`,
  - `ListDevices`, `ListCaptureApps`, `SetCapturedApps`, `ListSources`,
  - `SaveScene`, `LoadScene`, `ListScenes`,
  - `GetStatus`, `SubscribeMeters`.
- Process Tap capture backend (macOS 14.2+) for app-specific capture by bundle ID. When Process Tap
  capture is unavailable, LoopKit reports that state explicitly instead of presenting a silent fallback.
- Redirect-muted playback in Process Tap mode: captured apps are muted at source and heard through
  LoopKit's monitor output path.
- Monitor output render pipeline with automatic failover to default output when a selected device
  becomes unavailable.
- Control app UI for first-run setup, app selection, safe Monitor/Broadcast routes, monitor selection, health, and scenes.
- Menu-bar controller for master gain, monitor output, active captures, scene recall, and dashboard access.
- Physical microphone capture through the selected CoreAudio input device.

## App-specific quickstart

1. Launch LoopKit and complete setup to register the helper, verify BlackHole, and choose a physical Monitor.
2. Select one or more apps in **Sources**.
3. Confirm status shows `Process Tap` mode. If capture is unavailable, LoopKit shows a warning and
   does not claim that application audio is being captured.
4. In Discord, choose **BlackHole 2ch** as your microphone input.

## Build/test (engine)

```bash
cmake -S engine -B /tmp/loopkit-engine-build
cmake --build /tmp/loopkit-engine-build
ctest --test-dir /tmp/loopkit-engine-build --output-on-failure
```

## Build/test (Swift modules)

```bash
swift test
```

## Offline WAVE processing

```bash
swift run loopkit_offline_dsp app.wav output.wav \
  --mic-input mic.wav --app-gain 0.8 --mic-gain 1.0 --master-gain 1.0
# --gain and --mute remain aliases for application gain and mute.
```

The runner accepts mono or stereo 16-bit PCM and 32-bit float WAVE input and writes stereo
32-bit float WAVE output. It requires no audio hardware, `coreaudiod`, or elevated privileges.

## Install for friends

Tagged releases produce a universal **Community DMG** that is ad-hoc signed and does not require a paid Apple Developer membership. Mount it, drag LoopKit to Applications, and try to launch it. On the first launch, macOS will block the unnotarized app; follow [Apple's Open Anyway procedure](https://support.apple.com/102445), then complete LoopKit's first-run setup.

Verify the release's SHA-256 checksum before opening it. BlackHole 2ch remains a separate installation from its [official site](https://existential.audio/blackhole/). See [Releasing LoopKit](docs/RELEASING.md) for the exact trust model and installation steps.

## Local developer install

```bash
./installer/install_local.sh
```

The script runs tests, generates the combined Xcode project, and copies `LoopKit.app` to Applications. The app registers its embedded helper with `SMAppService`. The script never downloads or installs BlackHole.

To remove:

```bash
./installer/uninstall_local.sh
```

## Notes

- Target is macOS 14.2+.
- Application capture has no implicit virtual-device fallback; an unavailable Process Tap is surfaced
  as an error while microphone and other daemon functions remain available.
- In Process Tap mode, LoopKit uses redirect-muted playback (`CATapMuted`): captured apps no longer
  play directly to speakers and are heard through LoopKit monitor output.
- Community releases are ad-hoc signed, not notarized, and require a one-time Gatekeeper override.
- Optional Developer ID notarization tooling remains available but is not part of the default release workflow.
- Automatic updates and crash reporting are intentionally deferred.

LoopKit is available under the [MIT License](LICENSE). BlackHole is a separate project with its own license and release process.
