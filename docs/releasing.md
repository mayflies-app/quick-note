# Releasing

## Configuration

`VERSION` supplies the marketing version. The product and bundle names are `QuickNote` and `QuickNote.app`; the bundle identifier is `app.mayfiles.QuickNote`. A command-line `--version` override applies only to that build. Update `VERSION` for a persistent version change.

`macos-app.json` declares the GitHub repository, cask token, minimum macOS version, resources, and packaging settings. Before executing a release workflow, its `repository` value must match the actual GitHub repository running the workflow. The cask token is `quicknote`; the distribution tap is [mayflies-app/homebrew-tap](https://github.com/mayflies-app/homebrew-tap).

## Local Packaging

```sh
./scripts/app.py package
./scripts/app.py package --arch universal --sign developer-id
./scripts/app.py release --dry-run
```

Package defaults to Release, Universal, and ad-hoc signing. Use `--arch native|arm64|x86_64|universal`, `--configuration`, `--build`, `--output`, and `--sign auto|ad-hoc|developer-id` for explicit choices. Output contains an app under `app/`, a DMG, JSON metadata, and a SHA-256 checksum. The CLI verifies staged output before replacing the destination.

Developer ID packaging requires an available signing identity and Hardened Runtime. Signing settings use `MACOS_SIGNING_IDENTITY`, `MACOS_TEAM_ID`, and `CODE_SIGN_KEYCHAIN`. Local packaging does not submit notarization or publish artifacts. `release --dry-run` prints the release plan without executing it.

## GitHub Actions Release

The manually dispatched **macOS release** workflow uses the common `./scripts/app.py release` entrypoint. It defaults to `dry_run=true` and `publish=false`. With dry-run disabled, it builds one Universal Release package containing arm64 and x86_64, signs with Developer ID, submits its DMG once for Apple notarization, and staples the accepted result. Enable `publish` only for an authorized public release and cask update.

Configure these repository secrets before executing the workflow:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded Developer ID certificate and private key in PKCS#12 format |
| `MACOS_CERTIFICATE_PASSWORD` | PKCS#12 import password |
| `MACOS_SIGNING_IDENTITY` | Developer ID Application signing identity |
| `MACOS_TEAM_ID` | Apple Developer Team ID |
| `APPLE_NOTARIZATION_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARIZATION_ISSUER_ID` | App Store Connect API issuer ID |
| `APPLE_NOTARIZATION_PRIVATE_KEY` | API key private key |
| `HOMEBREW_TAP_TOKEN` | Token with permission to update the distribution tap |

The workflow uses its GitHub token for app release operations and a temporary signing keychain. Review the version, source commit, configured repository, permissions, and credentials before dispatching. Inspect retained workflow artifacts and logs for signing, notarization, and stapling results.

### Cache and Execution

Dry-run uses a dedicated `ubuntu-latest` preview job without Xcode, signing credentials or build-cache access. Execution uses the GitHub-hosted `xcode-27` runner. Release jobs are serialized and never cancel an in-progress release. Ordinary CI cancels superseded runs and retains tests, bundle builds and release-plan checks.

Debug and Release compilation caches are separate. Keys include actual Xcode, SDK and Swift fingerprints, build configuration, dependency/configuration hashes and the source SHA; fallback stays within the same compiler and dependency prefix. Cache paths exclude `dist` and credentials. Pull requests restore only; successful branch pushes may save Debug caches within GitHub's branch scope. Release dispatches on the default branch may save Release caches. Release cache hits and packaging timings require an executed release; dry-run previews do not exercise the Release compilation cache.

Tracked-input timestamps are reused only when content hashes, modes and checkout paths match the saved cache. Changed inputs still rebuild. Ordinary regression scripts share SDK compiler modules inside the existing build cache; fixtures and test execution are created afresh.

## Homebrew Distribution

Public distribution uses immutable, Developer ID signed, notarized release assets. The release workflow verifies downloaded assets against the prepared bytes and updates `Casks/quicknote.rb` in the distribution tap with the Universal DMG URL and checksum.

Maintain published casks through the release workflow so installation uses verified public release assets. See the tap's [distribution documentation](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md).
