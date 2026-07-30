# Releasing LoopKit

The default artifact is a universal **Community DMG**. It is ad-hoc signed, uses no paid Apple services, and is not notarized.

## Trust model

Ad-hoc signing gives the app and embedded helper stable code identifiers and lets LoopKit authenticate its own XPC connection. It does not establish a verified publisher identity and does not make Gatekeeper trust the download.

The SHA-256 file lets recipients confirm that their DMG matches the artifact published on the GitHub release page. It is not a replacement for Developer ID or Apple's malware scan. Recipients should install Community builds only when they trust the repository and release source.

Do not disable Gatekeeper globally and do not instruct users to remove quarantine attributes in Terminal.

## Local Community release

Run:

```bash
./scripts/community_release.sh 1.0.0
```

The script runs the C++ and Swift tests, builds universal `arm64 x86_64` Release products, ad-hoc signs the helper first and app last with hardened runtime, validates metadata and signatures, creates and verifies the DMG, and writes these artifacts under `dist/`:

- `LoopKit-1.0.0-Community.dmg`
- `LoopKit-1.0.0-Community.dmg.sha256`

## GitHub release

Open a pull request from a branch into `main`. After the merge, the `ci` workflow validates that exact commit. If every CI job succeeds, `.github/workflows/release.yml` builds the Community DMG, verifies it, creates the version tag, and publishes the DMG and checksum without Apple credentials or repository secrets.

Do not create or push release tags manually. The workflow derives a unique version from the major/minor values in `macos/ControlApp/project.yml` and the successful `ci` run number. For example, CI run 27 in the `1.0` release series becomes `v1.0.27`. Change `MARKETING_VERSION` on a branch when intentionally starting a new major or minor release series; its patch component is ignored by the automatic workflow.

The tag and GitHub Release are created only after the artifact has built and passed release validation. Pull-request CI never publishes a release.

Immediately before publication, the workflow verifies that its validated commit is still the head of `main`. If a newer merge has superseded it while the DMG was building, the older run exits successfully without creating a tag or changing `/releases/latest`; the newer run becomes the release candidate.

## Installing a Community release

1. Download both Community files from the same GitHub release.
2. In Terminal, open the download folder and run:

   ```bash
   shasum -a 256 -c LoopKit-1.0.0-Community.dmg.sha256
   ```

3. Mount the DMG and drag LoopKit to Applications.
4. Try to open LoopKit once. macOS will report that the developer cannot be verified or that Apple cannot check it for malicious software.
5. Open **System Settings → Privacy & Security**, scroll to Security, click **Open Anyway**, then confirm **Open**.
6. Complete LoopKit setup and approve its embedded helper if macOS asks.

The Gatekeeper exception applies to that installed build; users do not need to weaken system-wide security settings. Apple documents the same flow in [Safely open apps on your Mac](https://support.apple.com/102445).

## Optional notarized release

`scripts/release.sh` and `scripts/validate_release.sh` retain the Developer ID, notarization, stapling, and Gatekeeper-validation path in case the distribution policy changes later. That optional path requires Apple Developer Program membership, a Developer ID Application certificate, a Team ID, and App Store Connect notarization credentials. It is not invoked by the default GitHub workflow.
