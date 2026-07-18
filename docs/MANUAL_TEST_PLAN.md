# Manual Test Plan (Discord D&D Session)

## Setup

1. Run `./installer/install_local.sh`.
2. Launch `/Applications/LoopKit.app`.
3. In Discord, set input device to `BlackHole 2ch`.

## Routing checks

1. Select one or more running apps in **Captured Apps** without changing their output devices.
2. Confirm status shows `Process Tap` and Discord input meter moves.
3. Confirm selected app audio is heard through the LoopKit monitor output device (not direct source playback).
4. Drag an app port to **Monitor** again and confirm its Route disappears and local playback stops while its Broadcast Route continues.
5. Drag the app port back to **Monitor** and confirm the route and local playback return.
6. Disconnect the app from **Broadcast** and confirm Discord no longer receives it while local monitoring continues.
7. Add microphone Routes and confirm simultaneous speech + app audio in Discord.

## Mixer checks

1. Move app source gain slider and confirm expected level change.
2. Move mic gain slider and confirm expected level change.
3. Toggle mute/solo per source and verify behavior.
4. Adjust master gain and verify both sources scale.

## Scene checks

1. Save a scene with custom gains/mutes, distinct Monitor/Broadcast routes, and monitor output.
2. Change settings.
3. Load saved scene and confirm controls, routes, and monitor preference all restore.

## Recovery checks

1. Switch monitor output device while streaming.
2. Unplug selected monitor output.
3. Confirm LoopKit falls back to system default output and status reports fallback warning.
4. Replug/reselect original output and confirm fallback clears.

## Capture-unavailable check

1. Deselect or quit every tapped application, or run on a macOS version without Process Tap support.
2. Confirm diagnostics show **Unavailable** rather than **Fallback**.
3. Confirm LoopKit displays a capture warning and does not show a synthetic application Source.

## Soak test

1. Run Discord + background music + microphone for 2 hours.
2. Watch status underrun/overrun counters.
3. Validate no crash and no sustained dropout.
