# Releasing LoopKit

Public artifacts are universal, Developer ID-signed, notarized DMGs. There is no unsigned fallback.

## External prerequisites

- A GitHub repository with this repository configured as `origin`.
- Apple Developer Program membership and a **Developer ID Application** certificate.
- An App Store Connect API key authorized for notarization.
- A protected GitHub Environment named `release`.

Configure these `release` Environment secrets:

- `DEVELOPER_ID_APPLICATION` — the full signing identity name.
- `DEVELOPMENT_TEAM` — the ten-character Apple Team ID.
- `CERTIFICATE_P12_BASE64` — base64-encoded Developer ID certificate and private key.
- `CERTIFICATE_PASSWORD` — export password for that P12.
- `KEYCHAIN_PASSWORD` — random password used for the temporary CI keychain.
- `APP_STORE_CONNECT_KEY_ID` and `APP_STORE_CONNECT_ISSUER_ID`.
- `APP_STORE_CONNECT_KEY_BASE64` — base64-encoded App Store Connect `.p8` key.

## Local release

Export the five environment variables required by `scripts/release.sh`, then run:

```bash
./scripts/release.sh 1.0.0
```

The script runs tests, creates a universal Release build, signs helper first and app last, validates identities/privacy/icons/architectures, creates and signs a DMG, waits for notarization, staples and Gatekeeper-validates it, then writes a SHA-256 checksum under `dist/`.

## GitHub release

Set `MARKETING_VERSION` in `macos/ControlApp/project.yml`, commit it, and push a matching tag such as `v1.0.0`. The protected release job imports credentials into a temporary keychain and publishes only after every validation succeeds.
