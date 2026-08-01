# Manual Test Plan (Discord D&D Session)

## Setup

1. Install BlackHole 2ch from its official project if it is not already present.
2. Run `./installer/install_local.sh` for a developer build, or mount the Community DMG and drag LoopKit to Applications.
3. For a Community DMG, confirm the initial Gatekeeper block and use **System Settings → Privacy & Security → Open Anyway** once. Do not disable Gatekeeper globally.
4. Launch `/Applications/LoopKit.app` and complete first-run setup.
5. Confirm setup shows **Audio service: Ready** without a Background Helper or Login Items approval step.
6. Use the explicit optional microphone action. Confirm the prompt and Privacy & Security row are named **LoopKit** and use its icon; test both grant and denial/Settings recovery.
7. Refresh the optional application-audio test, choose Firefox, and confirm **Starting** becomes **Capturing**. Leave Firefox selected.
8. In Discord, set input device to `BlackHole 2ch`.
9. Close the dashboard and confirm audio continues from the menu bar; choose **Quit LoopKit** and confirm audio stops.

## Routing checks

1. Select one or more running apps in **Captured Apps** without changing their output devices.
2. Confirm status shows `Process Tap` and Discord input meter moves.
3. Confirm selected app audio is heard through the LoopKit monitor output device (not direct source playback).
4. Drag an app port to **Monitor** again and confirm its Route disappears and local playback stops while its Broadcast Route continues.
5. Drag the app port back to **Monitor** and confirm the route and local playback return.
6. Disconnect the app from **Broadcast** and confirm Discord no longer receives it while local monitoring continues.
7. Add microphone Routes and confirm simultaneous speech + app audio in Discord.
8. Confirm LoopKit refuses BlackHole as Monitor output and refuses to capture itself.
9. Confirm a communications-app Broadcast route asks for echo-risk approval before it is added.

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
5. Force an XPC connection interruption and confirm **Restart Audio Service** appears only in the fault state and reconnects successfully.

## Upgrade migration check

1. Start with the 1.0.7 LaunchAgent enabled or awaiting approval and existing saved routing state.
2. Install and open the new build.
3. Confirm the old agent is unregistered before the embedded XPC service connects and only one audio engine is active.
4. Confirm scenes, selected applications, routes, and device preferences survive.
5. Simulate an unregister failure and confirm setup blocks service startup, explains the migration fault, and offers retry plus Login Items settings.

## Capture-unavailable check

1. Deselect or quit every tapped application, or run on a macOS version without Process Tap support.
2. Confirm diagnostics show **Unavailable** rather than **Fallback**.
3. Confirm LoopKit displays a capture warning and does not show a synthetic application Source.

## Soak test

1. Run Firefox + microphone + Discord for at least 30 minutes.
2. Allow the startup grace period, then watch recent rates, queue fill, and scheduler discontinuities.
3. Validate clean audio, no crash, and no post-startup underrun growth.

## Release package checks

1. Confirm the app, XPC service, and transitional helper contain `arm64` and `x86_64` slices.
2. Confirm the app and XPC service have microphone and application-audio privacy descriptions, the audio-input entitlement, and LoopKit icon resources.
3. Confirm Finder, Dock, Launchpad, and app switcher show the LoopKit icon without transparency fringes.
4. Confirm the custom glyph remains legible in both light and dark menu bars.
5. Confirm `codesign --verify --deep --strict` succeeds and the app, XPC service, and transitional helper report `Signature=adhoc` with hardened runtime.
6. Confirm `shasum -a 256 -c` accepts the published checksum.
7. Confirm the Community build is not represented as notarized and that Gatekeeper requires the documented one-time override.
8. On a fresh user account, confirm no transitional LaunchAgent is registered.
