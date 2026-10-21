# Contributing

Focused bug fixes, documentation improvements, and reproducible reports are welcome. Discuss larger product changes before implementing them.

## Setup

Use the toolchain and common commands in [Development](docs/development.md). Read [Localization](docs/localization.md) before changing UI copy and [Releasing](docs/releasing.md) before changing packaging.

## Changes

Preserve the single-page note, stable paragraph IDs, rich text, SQLite transactions, input-method composition, undo, focus return, and save-or-cancel behavior. Keep native verification isolated from the everyday note. Maintain both supported UI languages without translating user content.

Shared scripts, workflows, and declared design and localization helpers are maintained in `homebrew-tap/templates/macos-app`. This repository declares its repository-relative helper destinations in the `shared` object of `macos-app.json`; app configuration, translations, product behavior and targeted checks belong here. Update shared implementation in the tap and synchronize from its root with explicit app checkout arguments after reviewing local and staged changes. Do not commit host-specific paths or assume a workspace layout. See [Shared Maintenance](https://github.com/mayflies-app/homebrew-tap/tree/main/templates/macos-app#shared-maintenance).

## Validation

Match validation to the change. For documentation only, check links, referenced paths and `git diff --check`; no app build or product test is needed. For executable changes, run `./scripts/app.py test` and the affected checks in [Development](docs/development.md). Build, package or inspect native UI only when the change affects those behaviors.

Reproduce a reported failure before fixing it; add regression coverage where existing checks leave a meaningful gap. Include fresh logs or screenshots for native interaction changes. Keep generated output, credentials, and signing files out of commits.

## Submission

Describe the user-visible problem, resulting behavior, and checks performed. Bug reports should include the app version, macOS version, Mac architecture, and reproduction steps. Redact personal note content and credentials.

Contributions use the [MIT license](LICENSE). Preserve copyright attribution.
