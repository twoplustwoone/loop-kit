# LoopKit v1 Architecture

## Audio defaults

- Sample rate: `48_000`
- Channels: stereo (non-interleaved float32)
- Daemon processing block: `512` frames
- Output ring capacity: `8_192` frames
- Output target fill: `1_536` frames
- Clock correction limit: `±0.5%`

## Components

1. **Swift package (`Package.swift`)**
   - `LoopKitEngine`: C++17 mixer and C API.
   - `LoopKitIPC`: XPC protocol and secure-coding DTOs shared by both processes.
   - `LoopKitAudioCore`: Objective-C++ adapters for Process Tap, microphone input, and AUHAL output.
   - `LoopKitDaemonCore`: runtime state, typed Routing Graph, DSP scheduling, device policy, and persistence.
   - `LoopKitUI`: hardware-independent SwiftUI design tokens and audio controls used by ControlApp.
   - `LoopKitOffline`: WAVE codec and block-based DSP runner with no CoreAudio dependency.
2. **Mixer Engine (`engine/`)**
   - App/mic source graph with gain, mute, solo, enable flags.
   - Master gain, soft clipper, peak/rms meters.
3. **Audio service (`macos/Daemon` + `macos/DaemonCore`)**
   - App-owned service embedded at `LoopKit.app/Contents/XPCServices/LoopKitAudioService.xpc` with a thin authenticated XPC facade around `LoopKitDaemonRuntime`.
   - Starts on demand through `NSXPCConnection(serviceName:)`, runs from `NSXPCListener.service()`, and exists only while LoopKit is running. Closing the dashboard preserves it through the menu-bar app; explicitly quitting LoopKit stops it.
   - Construction is side-effect-free. XPC resumes before asynchronous hardware startup progresses
     through `starting`, `ready`, `degraded`, or `failed`.
   - Process Tap backend (macOS 14.2+) captures selected app audio per bundle ID.
   - If Process Tap is unavailable, application capture is explicitly unavailable; LoopKit does not
     silently substitute an unconfigured virtual-device adapter.
   - Captures the selected microphone and processes app/mic buses through the engine.
   - Writes the Broadcast mix to external BlackHole 2ch and the Monitor mix to a physical output via AUHAL.
   - Uses redirect-muted capture (`CATapMuted`) plus monitor-output failover to system default.
   - Uses a monotonic host-clock scheduler and `AsyncResampler` output adapters. Producer and
     consumer cursors each have one owner; full queues reject new blocks rather than deleting unread audio.
   - Persists the active session atomically to versioned `state.json` after a 250 ms debounce and
     quarantines malformed state for diagnosis.
4. **Control App (`macos/ControlApp`)**
   - SwiftUI mixer and routing controls.
   - Imports `LoopKitUI` and `LoopKitIPC`; it has no direct engine or hardware access.
   - Polls the audio service for status and meter updates.
   - Shares one lifecycle-managed view model between the dashboard window and compact `MenuBarExtra` controller.
   - Owns first-run setup and requests microphone authorization from the foreground app through AVFoundation, ensuring the privacy prompt is attributed to LoopKit.
   - On upgrade, unregisters the prior `SMAppService` LaunchAgent before connecting. Failure blocks the new service so two audio engines cannot own devices at once.
5. **BlackHole 2ch (external CoreAudio driver)**
   - Receives the daemon's Broadcast mix; Discord selects BlackHole 2ch as its microphone input.
   - Is never bundled, downloaded, installed, or uninstalled by LoopKit.

6. **Offline DSP (`tools/loopkit_offline_dsp/`)**
   - Reads separate application and microphone PCM16 or float32 WAVE inputs, processes them through the same engine C interface,
     and writes stereo float32 WAVE output for repeatable local and CI verification.

## Routing safety defaults

- Microphone routes to Broadcast only.
- Normal captured apps route to Monitor and Broadcast.
- Communications apps route to Monitor only; adding Broadcast requires a persisted echo-risk acknowledgement.
- LoopKit cannot capture its own app identifier.
- The active Broadcast device cannot be selected as Monitor.

## Process identity and IPC

- App: `com.twoplustwoone.LoopKit`
- Embedded XPC service: `com.twoplustwoone.LoopKit.agent`
- IPC protocol version: `3`, negotiated with `LKXPCHandshake` before the client becomes connected.
- Community and Debug peers use identifier-only authentication because their signatures are ad-hoc.
- Optional Developer ID releases require the exact peer identifier, Apple signing anchor, and matching Team ID.

The legacy `Contents/Resources/loopkitd` executable and LaunchAgent plist remain embedded for one migration release only. Fresh installations never register them. Existing sessions, scenes, routes, and device preferences remain in their prior Application Support locations.

`captureMode` reports Process Tap capability, not whether a tap happens to be active. With no selected applications, setup reports **Ready to test**. A selected source with zero taps is **Starting** during reconciliation; a persisted warning after reconciliation is a capture fault.

## Scene schema

Scene files are stored under:

`~/Library/Application Support/LoopKit/scenes/*.json`

```json
{
  "schemaVersion": 1,
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

The active session uses a separate schema-versioned file at
`~/Library/Application Support/LoopKit/state.json`. It includes source state,
selected application identifiers, routes, input/Monitor preferences, and echo-risk acknowledgements.
