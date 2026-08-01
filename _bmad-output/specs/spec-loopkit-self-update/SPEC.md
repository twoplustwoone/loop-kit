---
id: SPEC-loopkit-self-update
companions:
  - update-behavior.md
  - release-contract.md
  - ../../project-context.md
  - ../../../docs/RELEASING.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability only — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# LoopKit Self-Update

## Why

LoopKit users cannot tell from the app whether their installed build is current and must discover, assess, and install releases through GitHub. LoopKit should first make update availability visible without changing its Community trust model, then add verified self-installation without hiding audio interruption, Gatekeeper status, or possible privacy-permission recovery.

## Capabilities

- **CAP-1**
  - **intent:** LoopKit can determine whether its installed version is older than the latest eligible published release.
  - **success:** Version comparison produces deterministic older, equal, newer, malformed, and prerelease outcomes.

- **CAP-2**
  - **intent:** A user can manually check whether LoopKit is current.
  - **success:** A manual check ends in an explicit up-to-date, update-available, or actionable failure result.

- **CAP-3**
  - **intent:** LoopKit can check for updates automatically without disrupting first run or normal audio work.
  - **success:** After first-run setup, LoopKit makes no more than one background request per 24 hours and does not interrupt the user when current or offline.

- **CAP-4**
  - **intent:** A user can notice and inspect an available update from normal LoopKit surfaces.
  - **success:** The app-menu command reaches the shared update state while dashboard and menu-bar availability surfaces show the same version and release details.

- **CAP-5**
  - **intent:** During Phase 1, a user can reach the authoritative release and complete the existing Community upgrade flow.
  - **success:** The update sheet opens the matching GitHub release through a clearly labeled manual handoff and never claims that LoopKit will install it.

- **CAP-6**
  - **intent:** During Phase 2, a user can obtain, verify, install, and relaunch into an eligible update.
  - **success:** An authentic update replaces LoopKit atomically, while invalid or interrupted updates leave the installed version runnable.

- **CAP-7**
  - **intent:** The release system can publish updater-consumable metadata for the exact eligible build.
  - **success:** Version, artifact URL, size, signature, compatibility, and release notes describe the same validated, non-superseded release.

- **CAP-8**
  - **intent:** Updating can coordinate with LoopKit lifecycle and audio ownership.
  - **success:** LoopKit warns before audio interruption, shuts down the app-owned XPC service cleanly, relaunches after installation, and provides recovery when installation cannot proceed.

## Constraints

- Phase 1 is update awareness only: Community DMG installation stays manual and the action is **View Release**, not **Update Now**.
- Automatic checks are enabled by default, run at most once per 24 hours after first-run setup, stay quiet on background failure, and never produce persistent UI when LoopKit is current.
- Update lifecycle belongs to ControlApp; Phase 1 must not change LoopKitIPC or give the audio service networking or updater responsibilities.
- Update availability is informational and uses existing LoopKit teal styling; it is not a setup step, warning, connection fault, or audio-health state.
- Phase 2 must support ad-hoc signed, explicitly unnotarized Community releases; Developer ID signing and notarization are not prerequisites. No flow may weaken Gatekeeper, remove quarantine, invoke `tccutil`, or promise that privacy permissions survive an update.
- Install and relaunch may stop Broadcast and Monitor audio only after the user is informed and chooses the install action.
- Phase 2 uses Sparkle 2 with signed archives, feed, and release notes; EdDSA is the publisher-authenticity root for Community updates and must not be represented as Apple trust.
- The stable appcast is served over HTTPS from GitHub Pages, release archives remain on GitHub Releases, and only the trusted current-`main` release job may access the protected private signing key.
- The EdDSA private key must have an encrypted offline backup and a documented loss or compromise recovery path because ad-hoc builds cannot rely on Developer ID key rotation.
- Phase 2 offers **Update and Relaunch** as the primary install action and **Install on Quit** as the secondary action; a deferred update is installed during a later normal quit and takes effect on the next launch.
- Silent automatic installation is initially excluded.
- Installed bundle versions and eligible release tags must remain monotonically increasing and semantically comparable.
- Update logic must be testable without GitHub, CoreAudio, permissions, or the XPC service.
- Xcode integration changes go through XcodeGen specifications, never generated project files.
- LoopKit must never download, install, update, or remove BlackHole.

## Non-goals

- Downloading or installing an update inside LoopKit during Phase 1.
- Silent automatic installation during the initial Phase 2 release.
- Updating BlackHole or any external prerequisite.
- Crash reporting, beta channels, phased rollout, delta updates, or a general Settings redesign.
- Changing the every-successful-current-`main` Community release cadence in Phase 1.
- Replacing the existing LoopKit visual system or commissioning Stitch exploration for the Phase 1 surfaces.

## Success signal

An older installed build detects the latest eligible release, exposes it consistently without disturbing audio or first-run setup, and takes the user to the matching Community release; a current or offline build remains unobtrusive. In Phase 2, an older installed build can verify and install an authentic update, briefly stop audio only with consent, relaunch successfully, and survive invalid or interrupted update attempts without losing the runnable installation.

## Assumptions

- `twoplustwoone/loop-kit` and its published releases remain publicly readable without application credentials.
- Release tags and `CFBundleShortVersionString` continue to identify the same release using `vMAJOR.MINOR.PATCH` and `MAJOR.MINOR.PATCH` forms.
