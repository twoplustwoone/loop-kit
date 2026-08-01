---
project_name: 'LoopKit'
user_name: 'Frisco'
date: '2026-08-01'
sections_completed: ['technology_stack', 'language_rules', 'framework_rules', 'testing_rules', 'quality_rules', 'workflow_rules', 'anti_patterns']
status: 'complete'
rule_count: 68
optimized_for_llm: true
---

# Project Context for AI Agents

_This file contains critical rules and patterns that AI agents must follow when implementing code in this project. Focus on unobvious details that agents might otherwise miss._

---

## Technology Stack & Versions

- Target macOS 14.2+; CI runs on `macos-14`.
- Swift 5.10 and Swift tools 5.10 for the main package; the standalone loopback test tool uses Swift tools 5.9 and macOS 14.
- C++17 realtime mixer and resampler, exposed through a C API and Swift C++ interoperability.
- CMake 3.20+ for standalone engine builds and CTest.
- XcodeGen 2.45+ with Xcode 15.3 project format; generated `.xcodeproj` files are not source files.
- SwiftUI for ControlApp and LoopKitUI; Foundation/XPC for IPC and persistence.
- CoreAudio, AudioToolbox, AVFoundation, CoreMedia, and AppKit at the hardware boundary.
- No third-party Swift package dependencies.
- IPC protocol version 3; app and service must remain mutually compatible.
- Community release artifacts support `arm64` and `x86_64`.

## Critical Implementation Rules

### Language-Specific Rules

- Keep UI views, permission handling, and `ObservableObject` state on `@MainActor`; keep XPC client state inside `LoopKitDaemonClient`, which is an actor.
- Serialize `LoopKitDaemonRuntime` control state on its dedicated queue. Perform slow hardware work on `maintenanceQueue`, then marshal results back before mutating runtime state.
- Keep CoreAudio and Process Tap APIs behind the Objective-C++ `LoopKitAudioCore` boundary; Swift code must not reach directly into hardware APIs.
- Any Swift or executable target importing `LoopKitDaemonCore` must enable C++ interoperability. XcodeGen targets require `SWIFT_OBJC_INTEROP_MODE: objcxx`; do not introduce a bridging header.
- Keep realtime C++ engine operations `noexcept`, validate audio pointers/frame counts, and clamp external numeric controls at the boundary.
- Represent domain failures with `LocalizedError`; convert service-operation failures into explicit `LKXPCResult` or status diagnostics at the XPC boundary.
- XPC DTOs remain `NSObject` + `NSSecureCoding`; decode allowed classes explicitly and provide defaults for fields absent from older archives.

### Framework-Specific Rules

- ControlApp may import `LoopKitUI` and `LoopKitIPC`, but must not access the engine or hardware directly.
- Keep `LoopKitUI` hardware-independent and reusable; place CoreAudio behavior in `LoopKitAudioCore` and runtime policy/state in `LoopKitDaemonCore`.
- Share one lifecycle-managed `LoopKitViewModel` between the dashboard and `MenuBarExtra`; closing the dashboard must not stop audio.
- The foreground app exclusively requests microphone permission through `MicrophoneAuthorizationController`. The XPC service may refresh permission state but must never prompt, invoke `tccutil`, or own TCC consent.
- The audio runtime is an embedded, app-owned XPC service. It starts on demand, remains active while the menu-bar app runs, and stops on explicit app quit.
- Keep the XPC executable shell thin and authenticated; `LoopKitDaemonRuntime` owns state, hardware orchestration, DSP scheduling, and persistence.
- Runtime construction must remain side-effect-free. Resume XPC before asynchronous hardware startup and expose progress through `starting`, `ready`, `degraded`, and `failed`.
- Complete the protocol-version handshake before treating the client as connected, and configure allowed XPC classes through the shared `configureLoopKitXPCInterface`.
- Use the domain term "Routing Graph" internally; reserve "ROUTING PATCHBAY" for deliberate UI copy.

### Testing Rules

- Run both `swift test` and the CMake/CTest engine suite for changes that cross Swift/C++ boundaries or affect DSP behavior.
- Keep policy, routing, persistence, IPC coding, scheduling, and offline DSP tests hardware-independent under `Tests/LoopKitTests`.
- Test engine and resampler behavior through the standalone C++ binaries; run the resampler stress test with Thread Sanitizer after queue, cursor, or atomic-ordering changes.
- Use the offline WAVE runner for deterministic end-to-end DSP verification without CoreAudio, `coreaudiod`, permissions, or elevated privileges.
- IPC changes require secure-coding round-trip tests, malformed-archive rejection, and legacy-field/default coverage.
- Persistence tests must cover schema versions, atomic round trips, corrupt-state quarantine, and legacy semantics—especially missing `routes` versus an explicitly empty route array.
- Routing changes must test safe defaults, atomic replacement, self-capture rejection, Broadcast/Monitor feedback prevention, and communications-app echo acknowledgement.
- Generate Xcode projects and build the affected macOS targets when changing XcodeGen specs, embedded-service wiring, entitlements, signing, or target dependencies.
- Use `docs/MANUAL_TEST_PLAN.md` for hardware, privacy, XPC lifecycle, migration, menu-bar continuity, feedback safety, soak, and release-package validation.
- Do not invent a coverage threshold; the repository currently enforces behavior through targeted regression suites and CI jobs.

### Code Quality & Style Rules

- Preserve module ownership: engine code in `engine/`, hardware adapters in `macos/AudioCore`, daemon policy/state in `macos/DaemonCore`, shared wire contracts in `macos/Shared`, reusable UI in `macos/LoopKitUI`, and app lifecycle/presentation in `macos/ControlApp`.
- Match the existing two-space indentation and local Swift/C++ style; no repository-wide formatter or linter configuration is currently authoritative.
- Prefer narrow visibility: keep helpers and file-local SwiftUI components `private` unless they form an intentional module boundary.
- Use the project vocabulary exactly: Source, Destination, Route, Routing Graph, Monitor, Broadcast, and Scene. Avoid the deprecated alternatives documented in `CONTEXT.md`.
- Preserve stable identifiers: microphone is `mic`, application Sources are `app:<bundle-id>`, and Destination IDs are `monitor` and `broadcast`.
- Normalize and sort bundle IDs, routes, scene names, and persisted collections where deterministic IPC or JSON output matters.
- Update `docs/ARCHITECTURE.md` whenever architecture defaults, process boundaries, or routing behavior changes.
- Comment compatibility, realtime, security, and lifecycle decisions that are not obvious from the code; avoid comments that merely restate implementation.
- Keep user-visible errors actionable and domain-specific while retaining detailed status counters and warnings for diagnosis.

### Development Workflow Rules

- Never develop or commit directly on `main`. Start each change on a focused branch created from an up-to-date `main`, then open a pull request targeting `main`.
- Keep `main` releasable; leave draft or incomplete work on its branch and wait for pull-request CI before merging.
- CI must retain its four validation areas: SwiftPM tests, CMake/CTest plus resampler TSAN and transport-symbol guard, generated macOS target builds, and the standalone loopback-tool build.
- There is no mandatory commit-message format documented; keep commits focused and describe the behavioral change clearly.
- Do not commit generated `.xcodeproj` directories. Change the corresponding XcodeGen `project.yml` and verify regeneration/build instead.
- Do not create or push release tags manually. After current `main` passes CI, the release workflow builds and validates the Community DMG before creating its tag and GitHub Release.
- Preserve the release freshness check: a superseded `main` workflow must not replace the latest release.
- Keep Community releases universal, ad-hoc signed, and explicitly unnotarized; never claim Apple notarization, malware scanning, or verified-publisher identity.
- BlackHole is an external prerequisite. Build, install, release, and uninstall scripts must never download, bundle, install, update, or remove it.
- Treat `installer/install_local.sh` as the full local-stack verification path; use direct SwiftPM, CMake, or generated-target builds for narrower changes.

### Critical Don't-Miss Rules

- Process Tap is the only application-capture backend. If unavailable, report `LKCaptureModeUnavailable` and a warning; never invent or silently activate a virtual-device fallback.
- Process Tap uses `CATapMuted` redirect-muted playback. Captured apps must be heard through LoopKit's Monitor path without simultaneous direct playback.
- Enforce routing safety in daemon policy, not only the UI: reject LoopKit self-capture, reject the active Broadcast device as Monitor, and require persisted acknowledgement before routing communications apps to Broadcast.
- Preserve safe defaults: microphone → Broadcast; normal apps → Monitor + Broadcast; communications apps → Monitor only.
- In scene compatibility, a missing `routes` field means legacy default routing; an explicitly empty array means disconnect every Source. Do not collapse these cases.
- Update the XPC protocol, both processes, secure-class configuration, tests, and compatibility version together. Legacy wire keys containing `discord` must remain even though Swift-facing names use `broadcast`.
- Keep scene schema definitions synchronized between `LKXPCScene` and `docs/ARCHITECTURE.md`; preserve version/default handling for older archives.
- Keep audio callbacks and render paths bounded and allocation-free: preallocate buffers, avoid blocking work, and preserve monotonic scheduling.
- Output/resampler queues have one producer and one consumer. When full, reject the new block and count an overrun; never advance a consumer cursor or delete unread audio from the producer side.
- The transitional raw helper and LaunchAgent are migration-only and dormant. Never register them on a fresh install; if old-agent removal fails, block the embedded service to prevent two audio engines.
- Permanent identities are `com.twoplustwoone.LoopKit` and `com.twoplustwoone.LoopKit.agent`; remaining `com.example` identifiers exist only for legacy cleanup and compatibility tests.
- Debug and Community XPC peers use identifier-only authentication because signing is ad hoc. Developer ID builds additionally require the Apple anchor and matching Team ID.
- Never invoke `tccutil`, weaken Gatekeeper, remove quarantine attributes, or represent Community builds as notarized.

---

## Usage Guidelines

**For AI agents:**

- Read this file before implementing code.
- Follow every applicable rule; when uncertain, prefer the safer or more restrictive behavior.
- Update this file when an implementation introduces a durable, non-obvious project pattern.

**For humans:**

- Keep this file lean and focused on agent needs.
- Update it when the stack, architecture, or workflow changes.
- Review it periodically and remove obsolete or newly obvious guidance.

Last Updated: 2026-08-01
