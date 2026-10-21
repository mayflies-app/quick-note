# Localization

## Supported Languages

Support Simplified Chinese (`zh-Hans`) and English (`en`). On first launch, select the first supported language in macOS preference order; use English if neither is present. Language choices use their own names: **简体中文** and **English**.

## Runtime Behavior

General settings presents equal-width language segments across the settings row, selected-state accessibility, a visible keyboard focus border, and Left/Right Arrow selection. Save an explicit selection immediately and update existing windows, menus, notices, errors, and accessibility labels without restarting.

Preserve note text, rich-text formatting, selection, input-method composition, and undo state when switching languages. System permission dialogs follow the macOS language independently.

## Adding UI Copy

Put app-owned translations, including typed errors and formatted values, in `Sources/QuickNoteCore/Resources/en.lproj/Localizable.strings` and `Sources/QuickNoteCore/Resources/zh-Hans.lproj/Localizable.strings`. Use the same keys and format arguments in both catalogs. Swift code selects a resource key through `AppLanguage.text` or formats a resource template through `AppLanguage.format`; do not embed paired translations in Swift.

SwiftPM processes these resources into `QuickNote_QuickNoteCore.bundle`. Xcode links the same local package and embeds its resource bundle. The common command-line builder declares this bundle in `macos-app.json` and copies it into the app. The shared `LocalizationResources` loader chooses the bundled resources for the selected language, with English and then the key as fallbacks. It does not rely on source files at runtime. Root `Resources/en.lproj/` and `Resources/zh-Hans.lproj/` contain only bundle display strings.

`AppLocalization` derives reverse lookup for existing native controls from the resource catalogs, so switching languages updates controls in place. Keep contextual keys separate when translations differ, such as the Edit menu and Editing settings page.

Use `QuickNote` for code and bundle identity, **Quick Note** for the English display name, and **随记** for Simplified Chinese. Use common settings labels: General, Appearance, Editing, Interface Language, Launch at Login, Keep on Top, Follow System, Light, and Dark.

Do not pass note content or editable fields through the UI catalog. Refresh existing controls instead of replacing the editor. Keep symbol buttons image-only when updating tooltips or accessibility labels.

## Validation

Run resource and localization unit tests with `./scripts/app.py test`. For a prebuilt bundle, use the common native localization entrypoint:

```sh
./scripts/app.py test --native --case localization \
  --app /Applications/QuickNote.app \
  --output /private/tmp/quick-note-localization --timeout-seconds 90
```

Use a visible macOS desktop and a fresh output directory. The existing product runner writes `manifest.json`, `localization-flow.json`, logs, and bilingual window previews. A native failure, incomplete check, timeout, or failed cleanup makes the run fail; inspect its artifacts before retrying.

The fixture uses an isolated database and preference suite, switches native Settings controls in both languages, checks all Settings pages and accessibility controls, and reads saved preferences in a second process. The runner normally stops only the selected QuickNote installation when it was already running, then restores that running state. It removes its exact isolated preference suite and SQLite database, WAL and shared-memory files on success, failure, timeout, or handled interruption, after confirming that its owned fixture processes have exited. Read-only persisted production preference snapshots, including the preference file’s presence or absence, and transaction-consistent SQLite snapshots establish preservation of the everyday note; logs, expected-value oracles, and screenshots remain available. Both the originally running and originally stopped application states are verified after cleanup. Keep the desktop free of other foreground interaction because the settings fixture also verifies real custom shortcut registration and focus transitions.

Production snapshots bracket normal stop, isolated fixture execution, and normal restoration. `fixtureProductionUnchanged` compares the complete state immediately before and after fixture execution; `productionDataAndPreferencesUnchanged` compares the complete initial and final state. A normal restoration change still fails the full preservation check. `productionStateChanges` lists changed preference keys, file-presence changes, and database changes for each interval without excluding window-frame keys or claiming to identify a writer. Raw preference plists and transaction-consistent SQL dumps are retained with owner-only permissions; no synthetic dump is created for an absent file.

The same entrypoint can exercise failure cleanup after a real native English language change. Set `MACOS_LOCALIZATION_TEST_MODE=fail` for a controlled fixture failure, or `MACOS_LOCALIZATION_TEST_MODE=hold` to hold the verified English settings window for the runner deadline or Ctrl-C. These modes apply only to the isolated `--verify-workflow --settings-only` fixture, never to ordinary application use.

The fixture writes `localization-progress.json` only after the actual English control, accessibility label, and screenshot have been verified. For Ctrl-C acceptance, wait for this checkpoint and interrupt the outer `scripts/app.py` process. Verify both SIGINT delivered to that PID and terminal Ctrl-C delivered to its owned foreground process group; confirm that ordinary app PIDs are outside that group before sending a group signal. For deadline acceptance, keep the same hold mode and use `--timeout-seconds 20`; confirm that the checkpoint preceded the timeout. In either case the manifest must fail and its independent `localizationFixture` observation must establish preference-suite and fixture-directory cleanup. `localization-flow.json` must still establish production-data preservation, original running-state restoration, removal of isolated SQLite files, and exit of owned fixture processes.
