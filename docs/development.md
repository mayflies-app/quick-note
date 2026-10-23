# Development

## Requirements

Use Xcode 27 or later, macOS SDK 27 or later, Swift 6.4 or later, and Python 3. The deployment minimum is macOS 14.0. Run commands from the repository root.

## Command-Line Workflow

```sh
./scripts/app.py build
./scripts/app.py run
./scripts/app.py test
./scripts/app.py package
./scripts/app.py release --dry-run
```

Build and Run default to Debug, the native architecture, and automatic signing. The bundle is `dist/dev/QuickNote.app`. Codex Run uses `./scripts/app.py run`: it builds, normally stops the same development app, and launches its replacement. Another running path with the same identity blocks Run. A build failure leaves the running app intact. Pass application arguments after `--`.

`macos-app.json` declares identity, resources, and build settings; `VERSION` supplies the marketing version. Common CLI code lives in `scripts/app.py` and `scripts/lib/` and uses SwiftPM for builds and tests.

Package defaults to Release, Universal, and ad-hoc signing under `dist/release/universal/`. See [Releasing](releasing.md) for Developer ID packaging. `release --dry-run` prints the release plan without building, launching, signing, or publishing.

Shared scripts, workflows, and declared design and localization helpers are maintained in `macos-app-tooling/templates/macos-app`. The `shared` object in this repository's `macos-app.json` declares helper destinations relative to this repository. Update shared implementation in macos-app-tooling, then run from its checkout root:

```sh
python3 -B scripts/sync_apps.py --check APP_CHECKOUT
python3 -B scripts/sync_apps.py --apply APP_CHECKOUT
```

Replace `APP_CHECKOUT` with this app's checkout directory; multiple explicit checkout arguments are accepted. The check is read-only; apply copies shared files. Review local and staged changes before applying and inspect the resulting diff. Checkouts can live in any directory: do not commit host-specific paths or a workspace layout. App configuration, translations, product behavior and targeted checks stay in this repository. Follow [Shared Maintenance](https://github.com/mayflies-app/macos-app-tooling/tree/main/templates/macos-app#shared-maintenance) for validation scope.

## Xcode Workflow

Open `QuickNote.xcodeproj` and select the `QuickNote` scheme for Build, Run, Debug or Archive. The native app target consumes the local Swift package libraries. Xcode and the CLI use the same product identity and bundled resources.

Debug and Release use ad-hoc signing by default and do not require an Apple Developer team. Hardened Runtime remains enabled. For Developer ID distribution, explicitly select your signing identity and team in Xcode, or use the command-line and CI workflow in [Releasing](releasing.md).

## Product Checks

`./scripts/app.py test` runs Swift tests for storage, rich-text editing, localization, settings, shortcuts, and window placement, followed by the offline native-verification contract checks in `Tests/Tools/test-native-verification.sh`. These checks use fake apps and helpers without opening the GUI. `macos-app.json` lists the additional checks in `testScripts`.

Native verification writes an isolated note and reads it in a separate process:

```sh
bash Tests/Tools/verify-native.sh --app "$PWD/dist/dev/QuickNote.app" \
  --output /private/tmp/quicknote-native
bash Tests/Tools/verify-native.sh --app "$PWD/dist/dev/QuickNote.app" \
  --output /private/tmp/quicknote-standard --appearance standard
```

Use an absolute app path, a new or empty output directory, and a visible macOS desktop. Results include logs, isolated database files, expected results, and window previews. Check actual login registration, Fn+Q permissions and conflicts, input-method candidates, or focus return when affected; the isolated fixture uses a mock login service and does not request Accessibility permission.

For a focused settings check, launch the prebuilt bundle with `--verify-workflow --settings-only --database /absolute/fresh/notes.sqlite`. Add `--shortcut-only` to check shortcut recording independently. Launch a second process with `--verify-workflow --settings-only --read-back --database` and the same isolated database to check persisted shortcut registration. These subsets report their own coverage; use the full runner for the complete editing workflow. Keep the desktop free of concurrent foreground interaction while verifying focus transitions and resolve any `INCONCLUSIVE` result before claiming that behavior passed.

For focused native window and keyboard checks, launch a prebuilt bundle with `--verify-workflow --window-shortcuts-only --database /absolute/fresh/notes.sqlite`. This single-process fixture uses isolated preferences, a mock login service and a temporary ⌃⌥⇧⌘5 global shortcut. It verifies bilingual Settings opening and closing through native key events, recording cancellation before Escape closes Settings, note save-on-close, existing editor shortcuts, and the Carbon callback when event posting is already permitted. Inspect `window-shortcuts.json`, the process log and window previews; keep the desktop free of concurrent interaction. The temporary preferences are removed when this subset finishes. Add `--undo-redo-only` for an actual edit → native Undo → native Redo check, or `--menu-shortcuts-only` for a probe of all Shift-letter main and popup menu equivalents with uppercase events. The menu probe keeps product windows hidden, temporarily substitutes a counting target and restores original actions, and writes `menu-shortcuts.json` without executing editing or clipboard commands.

For the shared bilingual UI check, run `./scripts/app.py test --native --case localization --app /Applications/QuickNote.app --output /private/tmp/quick-note-localization --timeout-seconds 90`. This invokes the existing product runner with a prebuilt bundle; it does not build or sign. See [Localization](localization.md) for coverage and restoration behavior.

`tools/GenerateIcon.swift` generates the iconset; use `iconutil` to update `Resources/AppIcon.icns`. Product verification tools belong in `Tests/Tools/`.
