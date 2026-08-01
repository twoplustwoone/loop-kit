# Release and Trust Contract

This companion defines the release, verification, and lifecycle rules that support `SPEC-loopkit-self-update`.

## Existing Release Invariants

- A successful current `main` CI run produces one universal Community DMG and matching SHA-256 file.
- The workflow derives a unique `MAJOR.MINOR.RUN_NUMBER` version, applies it to the built bundle, creates the matching `vMAJOR.MINOR.RUN_NUMBER` tag, and publishes a GitHub Release only after artifact validation.
- A run superseded by newer `main` must not publish or replace the latest release.
- Community artifacts are ad-hoc signed and unnotarized. The checksum detects an accidental mismatch but is not publisher authentication or an Apple malware scan.

## Phase 1 Release Discovery

- The authoritative discovery source is the latest public GitHub Release for `twoplustwoone/loop-kit`.
- Draft and prerelease builds are not eligible unless a later channel decision explicitly opts into them.
- The installed app version comes from bundle metadata, not hard-coded UI strings.
- The release tag is normalized by removing one leading `v` before comparison.
- Malformed or incomparable versions cannot produce an update-available result.
- Release details must retain the matching GitHub release URL; Phase 1 does not construct an installer URL and does not download executable content.
- The last background-attempt time and last successful result may be cached locally. Tests use injected release data and time rather than live GitHub calls.

## Phase 2 Authenticity

- Sparkle 2 owns download, verification, atomic replacement, authorization when needed, and relaunch behavior.
- Use a reviewed Sparkle release with Sparkle 2.9 as the minimum feature baseline for signed feeds and verification before extraction.
- Ad-hoc Community builds remain supported; Developer ID signing and notarization are not prerequisites.
- EdDSA is the publisher-authenticity root for Community self-updates and must not be described as Apple code signing or notarization.
- Each eligible update archive carries a valid EdDSA signature corresponding to the public key embedded in the installed app.
- The public key is committed in ControlApp `Info.plist` as `SUPublicEDKey`; it is not secret.
- The stable feed URL is `https://twoplustwoone.github.io/loop-kit/appcast.xml`, deployed through GitHub Pages.
- Update archives remain assets on their matching GitHub Releases. A release is published before its appcast entry is deployed, so a Pages failure leaves clients on the previous valid feed.
- The archive, appcast, and release notes are signed. LoopKit enables Sparkle feed-signature validation and verification before extraction.
- Updater metadata and release notes refer to the same exact artifact and version.

## Private-Key Custody

- Generate the EdDSA key offline with Sparkle tooling.
- Retain the private key in the maintainer macOS login Keychain and in a separately encrypted offline backup.
- Store the CI copy as the `SPARKLE_EDDSA_PRIVATE_KEY` secret in a release-only GitHub Actions environment restricted to trusted current-`main` release jobs.
- Pull-request jobs cannot access the key. The release job passes it to Sparkle signing tools through standard input and does not persist it on the runner.
- Never commit the private key, publish it to Pages or Releases, write it to logs, or expose it through a general repository variable.
- Losing, exposing, or unintentionally rotating the key is release-blocking. Because ad-hoc builds cannot rely on Developer ID key rotation, the recovery plan must cover feed suspension and a manual Community update that establishes a replacement key when necessary.

## App and Audio Lifecycle

- Update orchestration lives in ControlApp. The XPC protocol and daemon do not fetch, compare, download, or install updates.
- The user must consent before an installation action stops LoopKit audio.
- **Update and Relaunch** is the primary install action. **Install on Quit** is secondary and installs a downloaded, verified update during a later normal quit so it takes effect on the next launch.
- A deferred update remains visible and may still be installed immediately; deferral must not create competing updater sessions.
- Update relaunch must terminate the app-owned audio XPC service before replacing the enclosing app bundle.
- Failure before replacement leaves the current application and service usable.
- Failure after a committed replacement must produce a recoverable result rather than two concurrently active audio engines.

## Verification Obligations

### Phase 1

- Unit-test version normalization and ordering, including current, older, newer, malformed, and prerelease values.
- Unit-test release-response parsing, eligibility, caching interval, manual override, and background-versus-manual error presentation.
- Build the generated ControlApp target after changing XcodeGen or app-menu integration.
- Demonstrate the dashboard and menu-bar surfaces from injected current, available, checking, and failure states.

### Phase 2

- Test a genuine older installed release updating to a newer release artifact.
- Test invalid signatures, corrupt or truncated downloads, unavailable appcast, unwritable installation location, cancellation, and interrupted installation.
- Test updating while audio is active, clean XPC shutdown, successful relaunch, and absence of a second audio engine.
- Validate the final release package and its nested signatures using the repository release validation path.
- Exercise both supported architectures or prove the universal artifact used by the updater contains both.
