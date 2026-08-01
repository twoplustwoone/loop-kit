---
title: 'Phase 1 update checking'
type: 'feature'
created: '2026-08-01'
status: 'done'
review_loop_iteration: 0
baseline_commit: '1ef8e68fa2cfb799b9480e6416b62189c7a4eda7'
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/specs/spec-loopkit-self-update/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-loopkit-self-update/update-behavior.md'
  - '{project-root}/_bmad-output/specs/spec-loopkit-self-update/release-contract.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** LoopKit cannot tell Community-build users when a newer GitHub release exists, so users must discover releases themselves and cannot verify their installed version from the app.

**Approach:** Add a hardware-independent release checker and a single app-scoped update controller. Check quietly after first-run setup at most once per 24 hours, support explicit checks from the app menu, and present an available release in the dashboard and menu bar with a safe handoff to its GitHub page.

## Boundaries & Constraints

**Always:** Keep ad-hoc Community builds supported; treat GitHub Releases as the Phase 1 authority; use semantic version comparison; share one state and in-flight request across all app surfaces; persist every automatic attempt and the last valid release; make background failures silent and manual results explicit; expose accessible text labels; keep update work in the foreground ControlApp and hardware-independent Swift code.

**Ask First:** Changing the public release/tag convention, repository identity, 24-hour cadence, first-run gate, or manual-download handoff; adding a dependency or server; changing signing/distribution policy; expanding into download, verification, installation, relaunch, Sparkle, or Install on Quit.

**Never:** Modify daemon/IPC/audio behavior; install or replace the app; infer/download release assets; claim that View Release installs an update; treat drafts, prereleases, malformed versions, non-HTTPS URLs, or older releases as available; remove Gatekeeper guidance; block launch or audio when checking fails.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Automatic check | Setup complete; no attempt within 24h | Fetch latest stable release once and cache the attempt/result | Failure is silent; timestamp still throttles retries |
| Automatic suppressed | Setup incomplete, request in flight, or attempt less than 24h ago | No network request; retain valid cached availability | No user-facing error |
| Manual check | App-menu action at any cadence | Present checking, bypass cadence, then show current or available | Present actionable error with Try Again/Close |
| Newer release | Valid latest version is greater than installed | Persist release; show teal dashboard pill and menu-bar action; sheet shows versions/notes | View Release opens the exact HTTPS GitHub URL; Later hides sheet only |
| No update | Latest version is equal to or older than installed | Report current only for a manual check; never offer downgrade | Invalid/incomparable versions fail safely |
| Concurrent triggers | Automatic/manual/surface triggers overlap | Join one in-flight fetch; a manual trigger promotes the joined result to visible UI | Never issue competing requests |
| Cached release | App relaunches with a valid cached release | Re-compare against installed version before restoring availability | Ignore malformed or no-longer-newer cache |

</frozen-after-approval>

## Code Map

- `Package.swift` -- declare the Foundation-only `LoopKitUpdate` product/target and test dependency.
- `macos/Update/Sources/LoopKitVersion.swift` -- strict SemVer parsing and comparison.
- `macos/Update/Sources/GitHubRelease.swift` -- eligible release DTO and defensive decoding.
- `macos/Update/Sources/UpdateCheckService.swift` -- injected fetching/time, in-flight deduplication, result classification, and cadence policy.
- `macos/Update/Sources/UpdateCheckPersistence.swift` -- narrow cache protocol and production UserDefaults store.
- `macos/ControlApp/project.yml` -- link `LoopKitUpdate` into the generated ControlApp project.
- `macos/ControlApp/Sources/LoopKitUpdateViewModel.swift` -- app-scoped observable adapter, installed-version provider, cache-race protection, and manual/background presentation policy.
- `macos/ControlApp/Sources/LoopKitUpdateView.swift` -- themed checking/current/available/error sheet and browser handoff.
- `macos/ControlApp/Sources/App.swift` -- shared ownership, lifecycle trigger, and Check for Updates… app command.
- `macos/ControlApp/Sources/ContentView.swift` -- first-run eligibility, update pill, and sole sheet presenter.
- `macos/ControlApp/Sources/MenuBarControllerView.swift` -- available-update footer action routed through the dashboard presenter.
- `Tests/LoopKitTests/LoopKitUpdateTests.swift` -- deterministic unit coverage without live GitHub.
- `docs/RELEASING.md` -- Community update-discovery/manual-install contract.

## Tasks & Acceptance

**Execution:**
- [x] `Package.swift`, `macos/Update/Sources/`, `Tests/LoopKitTests/LoopKitUpdateTests.swift` -- implement and test strict version comparison, eligible GitHub release parsing, 24-hour scheduling, cache revalidation, injected I/O, and concurrency policy.
- [x] `macos/ControlApp/project.yml`, `macos/ControlApp/Sources/LoopKitUpdateViewModel.swift`, `macos/ControlApp/Sources/App.swift` -- wire one production controller, background activation checks, and the manual app command without touching audio lifecycle.
- [x] `macos/ControlApp/Sources/LoopKitUpdateView.swift`, `macos/ControlApp/Sources/ContentView.swift`, `macos/ControlApp/Sources/MenuBarControllerView.swift` -- add accessible status/actions and one coordinated presentation path using existing design tokens.
- [x] `docs/RELEASING.md` -- document that Phase 1 discovers releases and opens GitHub while users still download and install the Community DMG manually.

**Acceptance Criteria:**
- Given a completed setup and eligible cadence, when LoopKit activates, then it performs at most one background request and never exposes background checking/current/error UI.
- Given any cadence or setup state, when Check for Updates… is chosen, then one visible check ends in current, available, or retryable error UI.
- Given a newer valid stable release, when either update affordance is activated, then the dashboard presents installed/available versions, release notes, View Release, and Later; the exact release URL opens only on View Release.
- Given Later or a relaunch, when the release remains newer, then availability persists while sheet dismissal remains non-persistent.
- Given a development preview/snapshot, when update UI is rendered, then no live request is made and deterministic states cover long versions and notes.

## Spec Change Log

## Design Notes

`LoopKitUpdate` remains UI- and hardware-independent so scheduling, parsing, and comparison are testable with injected fetch, clock, and persistence. The ControlApp owns one observable adapter rather than extending the audio-focused `LoopKitViewModel`; the dashboard owns the only sheet, and menu/app-command actions open it to avoid competing presenters.

Record `lastAutomaticAttemptAt` immediately before network I/O. Accept one leading `v`, require three numeric core components, apply SemVer prerelease precedence, and ignore build metadata. Reject draft/prerelease responses and invalid HTTPS release URLs defensively even when using `/releases/latest`.

Production checks call `https://api.github.com/repos/twoplustwoone/loop-kit/releases/latest` with GitHub JSON Accept and identifiable User-Agent headers. Treat an absent `LoopKitFirstRunSetupComplete` preference as false for automatic checks; manual checks remain available. Preview and snapshot arguments receive injected state and never create a production fetcher.

## Verification

**Commands:**
- `swift test` -- all release/version/scheduling/cache/presentation-policy tests pass without network access.
- `xcodegen generate --spec macos/ControlApp/project.yml --project macos/ControlApp` -- generated project includes `LoopKitUpdate`.
- `xcodebuild -project macos/ControlApp/LoopKit-ControlApp.xcodeproj -scheme ControlApp -configuration Debug -derivedDataPath .build/macos/ControlApp build` -- ControlApp builds.

**Manual checks (if no CLI):**
- Inspect dashboard at 1080×720 and menu bar at 360×480 for available/current/checking/error states, long release notes, keyboard/Escape behavior, accessible labels, silent background failures, and exact GitHub handoff.

## Suggested Review Order

**App orchestration**

- Start with the single app-owned update state shared across every surface.
  [`App.swift:6`](../../macos/ControlApp/Sources/App.swift#L6)

- Follow background/manual requests, cache-race protection, presentation policy, and browser failure handling.
  [`LoopKitUpdateViewModel.swift:7`](../../macos/ControlApp/Sources/LoopKitUpdateViewModel.swift#L7)

- Confirm the native application-menu entry opens the sole dashboard window.
  [`App.swift:126`](../../macos/ControlApp/Sources/App.swift#L126)

**Release trust and scheduling**

- Review cadence enforcement, in-flight deduplication, caching, and result classification together.
  [`UpdateCheckService.swift:113`](../../macos/Update/Sources/UpdateCheckService.swift#L113)

- Inspect the concrete GitHub request and defensive HTTP/decoding boundary.
  [`UpdateCheckService.swift:32`](../../macos/Update/Sources/UpdateCheckService.swift#L32)

- Verify only the exact repository release URL and stable tag become eligible.
  [`GitHubRelease.swift:31`](../../macos/Update/Sources/GitHubRelease.swift#L31)

- Check strict semantic-version normalization and prerelease ordering independently.
  [`LoopKitVersion.swift:3`](../../macos/Update/Sources/LoopKitVersion.swift#L3)

**User experience**

- Review first-run gating, activation checks, update pill, and coordinated sheet presentation.
  [`ContentView.swift:94`](../../macos/ControlApp/Sources/ContentView.swift#L94)

- Inspect available-release content, release notes, keyboard actions, and accessible terminal states.
  [`LoopKitUpdateView.swift:6`](../../macos/ControlApp/Sources/LoopKitUpdateView.swift#L6)

- Confirm the compact update row preserves existing menu-bar footer actions.
  [`MenuBarControllerView.swift:243`](../../macos/ControlApp/Sources/MenuBarControllerView.swift#L243)

**Verification and integration**

- Begin tests at the production HTTP boundary, then continue through cadence and concurrency cases.
  [`LoopKitUpdateTests.swift:86`](../../Tests/LoopKitTests/LoopKitUpdateTests.swift#L86)

- Verify SwiftPM exposes the hardware-independent module to app and tests.
  [`Package.swift:15`](../../Package.swift#L15)

- Finish with the documented Community manual-update contract.
  [`RELEASING.md:36`](../../docs/RELEASING.md#L36)
