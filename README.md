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
- `installer/`: local unsigned install/uninstall scripts for personal-machine usage.

## What is implemented

- C++ mixer engine with:
  - app + mic sources,
  - per-source gain/mute/solo/enabled,
  - master gain,
  - soft clipping,
  - peak/rms meters.
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
- Control app UI for app selection, per-source controls, editable Monitor/Broadcast routes, monitor selection, status, and scene actions.
- Menu-bar controller for master gain, monitor output, active captures, scene recall, and dashboard access.
- Physical microphone capture through the selected CoreAudio input device.

## App-specific quickstart

1. Start `ControlApp` and select one or more apps in **Captured Apps**.
2. Choose a physical monitor output device in **Monitor Output**.
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
swift run loopkit_offline_dsp input.wav output.wav --gain 0.8 --master-gain 1.0
# Use --mute to verify a silent application Source.
```

The runner accepts mono or stereo 16-bit PCM and 32-bit float WAVE input and writes stereo
32-bit float WAVE output. It requires no audio hardware, `coreaudiod`, or elevated privileges.

## Local install (unsigned, personal machine)

```bash
./installer/install_local.sh
```

The script ensures BlackHole 2ch is available, generates Xcode projects, builds the daemon and app,
and installs:

- BlackHole 2ch as the Discord-facing virtual audio device when it is not already installed
- daemon binary to `~/Library/Application Support/LoopKit/bin/loopkitd`
- launch agent to `~/Library/LaunchAgents/com.example.LoopKit.loopkitd.plist`
- app to `/Applications/LoopKit.app`

To remove:

```bash
./installer/uninstall_local.sh
```

## Notes

- Target is macOS 14+.
- Process Tap capture requires macOS 14.2+.
- Application capture has no implicit virtual-device fallback; an unavailable Process Tap is surfaced
  as an error while microphone and other daemon functions remain available.
- In Process Tap mode, LoopKit uses redirect-muted playback (`CATapMuted`): captured apps no longer
  play directly to speakers and are heard through LoopKit monitor output.
- This repository currently assumes local unsigned development workflows.
- Full production-hardening (long soak tuning, robust CoreAudio edge cases, distribution signing)
  is not complete yet.
