# Update Behavior

This companion defines the behavioral states and surfaces for `SPEC-loopkit-self-update`. Visual implementation inherits the existing native macOS controls and `LoopKitTheme` tokens.

## Phase Boundary

| Behavior | Phase 1 | Phase 2 |
|---|---|---|
| Detect latest eligible release | Yes | Yes |
| Show release details | Yes | Yes |
| Download inside LoopKit | No | Yes |
| Verify executable update | No | Yes, with EdDSA |
| Replace and relaunch LoopKit | No | Yes |
| Silent automatic install | No | No |

Phase 1 and Phase 2 ship in separate pull requests. Phase 1 must not anticipate Phase 2 by presenting controls it cannot complete.

## Check Triggers

| Trigger | Required behavior |
|---|---|
| First-run setup active | Do not check automatically. |
| Eligible launch or activation | Check only when no successful or failed background attempt has occurred within 24 hours. |
| **Check for Updates…** | Check immediately regardless of the background interval. |
| Background offline, malformed, or rate-limited response | Record the attempt and remain silent. |
| Manual offline, malformed, or rate-limited response | Explain that the check could not complete and offer retry. |

Automatic checking is enabled by default. Phase 1 does not add a preference or skipped-version state.

## State Contract

| State | Persistent presentation | Manual-check presentation | Available actions |
|---|---|---|---|
| Not checked | None | Checking progress after invocation | Cancel only if the check is visibly long-running |
| Checking automatically | None | N/A | None |
| Checking manually | None outside the invoked surface | Progress | None or Cancel |
| Current | None | Installed version is current | Close |
| Update available | Dashboard pill and menu-bar action | Release sheet | **View Release**, **Later** |
| Check failed automatically | None | N/A | None |
| Check failed manually | None outside the invoked surface | Actionable error | **Try Again**, **Close** |
| Phase 2 downloading | Update sheet | Progress and size when known | Cancel before installation begins |
| Phase 2 ready to install | Update sheet | Restart and audio-interruption notice | **Update and Relaunch**, **Install on Quit**, **Later** |
| Phase 2 install deferred | Pending-update indicator | Update will install when LoopKit quits | **Update and Relaunch**, **Later** |
| Phase 2 installation failed | No false success state | Actionable recovery | Retry or retain current version |

All surfaces observe one shared update state. They must not issue independent competing checks or disagree about the available version.

## Surfaces

### Application Menu

- Add standard macOS **Check for Updates…** placement under the LoopKit application menu.
- The command remains available when no update is known and initiates CAP-2.

### Dashboard

- Show a compact teal `UPDATE <version>` pill in the top bar only when an update is available.
- Activating the pill opens the release sheet.
- Do not place update state inside Setup or reuse connection and audio-health indicators.

### Menu-Bar Controller

- Show an **Update available** action in the footer when applicable.
- Preserve access to Setup and Open Dashboard without overcrowding persistent current-state UI.

### Release Sheet

- Show installed version, available version, release notes, and the current phase's actions.
- Phase 1 primary action is **View Release**; it opens the authoritative matching GitHub release.
- **Later** dismisses the sheet without suppressing future availability presentation.
- Do not offer **Skip This Version** in Phase 1.

## Install Interruption

Before a Phase 2 install action, state that LoopKit will restart and Broadcast and Monitor audio will stop briefly. Community UX must also state that macOS may request privacy confirmation again after the update; it must not suggest weakening system security.

**Install on Quit** means the update is already downloaded and verified, but LoopKit keeps the current version running until the user later quits normally. Sparkle installs during that quit, so the next launch uses the new version. This avoids interrupting an active audio session but can defer the update indefinitely for menu-bar users who rarely quit. **Update and Relaunch** is the primary action; **Install on Quit** is secondary, and a pending update remains discoverable until installation completes.

## Accessibility Floor

- Every icon-only entry has a meaningful accessibility label and help text.
- Availability is conveyed by text and semantics, not teal alone.
- Menu and sheet actions are keyboard reachable and follow native focus order.
- Progress and terminal results are announced without repeatedly announcing background checks.
