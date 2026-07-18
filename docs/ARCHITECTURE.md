# LoopKit v1 Architecture

## Audio defaults

- Sample rate: `48_000`
- Channels: stereo (non-interleaved float32)
- Daemon processing block: `512` frames

## Components

1. **Swift package (`Package.swift`)**
   - `LoopKitEngine`: C++17 mixer and C API.
   - `LoopKitIPC`: XPC protocol and secure-coding DTOs shared by both processes.
   - `LoopKitAudioCore`: Objective-C++ adapters for Process Tap, microphone input, and AUHAL output.
   - `LoopKitDaemonCore`: daemon state, routing, DSP loop, device policy, and scene persistence.
   - `LoopKitUI`: reusable SwiftUI design tokens and audio controls with no daemon dependency.
   - `LoopKitOffline`: WAVE codec and block-based DSP runner with no CoreAudio dependency.
2. **Mixer Engine (`engine/`)**
   - App/mic source graph with gain, mute, solo, enable flags.
   - Master gain, soft clipper, peak/rms meters.
3. **Daemon (`macos/Daemon` + `macos/DaemonCore`)**
   - Thin mach-service executable around `LoopKitDaemonCore`.
   - Process Tap backend (macOS 14.2+) captures selected app audio per bundle ID.
   - If Process Tap is unavailable, application capture is explicitly unavailable; LoopKit does not
     silently substitute an unconfigured virtual-device adapter.
   - Captures the selected microphone and processes app/mic buses through the engine.
   - Writes the Broadcast mix to BlackHole 2ch and the Monitor mix to a physical output via AUHAL.
   - Uses redirect-muted capture (`CATapMuted`) plus monitor-output failover to system default.
4. **Control App (`macos/ControlApp`)**
   - SwiftUI mixer and routing controls.
   - Polls daemon for status and meter updates.
   - Shares one lifecycle-managed view model between the dashboard window and compact `MenuBarExtra` controller.
5. **BlackHole 2ch (external CoreAudio driver)**
   - Receives the daemon's Broadcast mix; Discord selects BlackHole 2ch as its microphone input.

6. **Offline DSP (`tools/loopkit_offline_dsp/`)**
   - Reads mono/stereo PCM16 or float32 WAVE input, processes it through the same engine C interface,
     and writes stereo float32 WAVE output for repeatable local and CI verification.

## Scene schema

Scene files are stored under:

`~/Library/Application Support/LoopKit/scenes/*.json`

```json
{
  "name": "My DnD Scene",
  "masterGain": 1.0,
  "monitorDeviceUID": "AppleHDAEngineOutput:...",
  "capturedAppBundleIDs": [
    "com.spotify.client",
    "org.mozilla.firefox"
  ],
  "captureModePreference": "processTapPreferred",
  "playbackPolicy": "redirectMuted",
  "routes": [
    {
      "sourceID": "app:com.spotify.client",
      "destinationID": "broadcast"
    },
    {
      "sourceID": "mic",
      "destinationID": "monitor"
    }
  ],
  "sources": [
    {
      "id": "app:com.spotify.client",
      "displayName": "Spotify",
      "gain": 0.9,
      "mute": false,
      "solo": false,
      "enabled": true
    },
    {
      "id": "mic",
      "displayName": "Microphone",
      "gain": 1.0,
      "mute": false,
      "solo": false,
      "enabled": true
    }
  ]
}
```

Route destination IDs are `monitor` and `broadcast`. A missing `routes` field is
treated as a legacy scene and routes every source to both destinations; an empty
array intentionally disconnects every source.
