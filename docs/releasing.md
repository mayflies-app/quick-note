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

The manually dispatched **macOS release** workflow uses the common `./scripts/app.py release` entrypoint. It defaults to `dry_run=true` and `publish=false`. With dry-run disabled, it builds one Universal Release package containing arm64 and x86_64, signs with Developer ID, submits its DMG for Apple notarization, and staples the accepted result. Enable `publish` only for an authorized public release and cask update.

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

Dry-run uses the `preview` job on `ubuntu-latest`, without credentials or build-cache access. Execution follows `preflight → package → notarize → publish → cask`, using the common `./scripts/app.py release --execute --stage <job>` entrypoint. `package` and `notarize` use GitHub-hosted `xcode-27` with Xcode 27; the other jobs use `ubuntu-latest`. Signing secrets are scoped to `package`, notarization secrets and Team ID to `notarize`, Contents write to `publish`, and `HOMEBREW_TAP_TOKEN` to `cask`. `publish=false` stops after notarization. A matching public version reuses verified public assets and skips rebuilding and notarization. Release runs are serialized and never cancel an in-progress execution.

Use **Re-run failed jobs** or re-run a failed job itself to reuse successful upstream work. Jobs download immutable inputs by the producer's artifact ID; the signed app travels in a tar archive preserving executable modes and symlinks. Notarization resumes a retained submission ID after checking the original DMG checksum. Draft publication verifies existing bytes and uploads only missing assets. Empty `starter` placeholders from failed uploads are removed only after all completed assets pass byte verification; an already published release is verified without further writes. Missing artifact IDs stop before download, without falling back to all artifacts. A cask retry only verifies public assets and updates the tap. Build cache saving completes in `package` even if a later job fails.

Keep workflow artifacts until completion. Expired inputs require a new run. If a prior notary execution has no retained submission ID, inspect Apple submission history before starting a new workflow run. Re-running all jobs can produce different signed bytes that cannot reuse the previous checkpoint. See [shared release retries](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md#retry-a-failed-job) for recovery boundaries. Ordinary CI retains tests, bundle builds and release-plan checks.

Debug and Release compilation caches are separate. Keys include actual Xcode, SDK and Swift fingerprints, build configuration, dependency/configuration hashes and the source SHA; fallback stays within the same compiler and dependency prefix. Cache paths exclude `dist` and credentials. Pull requests restore only; successful branch pushes may save Debug caches within GitHub's branch scope. Release dispatches on the default branch may save Release caches. Release cache hits and packaging timings require an executed release; dry-run previews do not exercise the Release compilation cache.

Tracked-input timestamps are reused only when content hashes, modes and checkout paths match the saved cache. Changed inputs still rebuild. Ordinary regression scripts share SDK compiler modules inside the existing build cache; fixtures and test execution are created afresh.

## Homebrew Distribution

Public distribution uses immutable, Developer ID signed, notarized release assets. The release workflow verifies downloaded assets against the prepared bytes and updates `Casks/quicknote.rb` in the distribution tap with the Universal DMG URL and checksum.

Maintain published casks through the release workflow so installation uses verified public release assets. See the tap's [distribution documentation](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md).

## Release Diagnostics

Release logs identify stages, failure kinds and external exit codes, with credential-safe
GitHub error annotations. See [shared release diagnostics](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md#release-diagnostics)
for authentication, authorization, repository access, network, concurrency and validation errors.
Tap updates use `HOMEBREW_TAP_TOKEN`, separately from the app workflow token.

A tap failure after successful publication leaves the release assets published. Repair
the cask from those verified public assets; do not rebuild or replace the same version.
Only confirmed concurrent push rejection is rebased and retried.
