# Quick Note

A native, single-page macOS note. Open it with a shortcut, write, then hide it and return to the same page later. Notes use AppKit rich text and local SQLite storage; no account or network is required.

## Features

- Show or hide the editor from any app and return focus to the previous app.
- Write headings, lists, checklists, quotes and monospaced text with native editing.
- Apply fonts, colors, highlights, links and paragraph alignment.
- Use native selection, rich-text paste, undo, find, spell checking and input methods.
- Save automatically, choose English or Simplified Chinese and optionally launch at login.

## Requirements

macOS 14 or later, on Apple Silicon or Intel. The default shortcut needs no Accessibility permission; the optional Fn+Q shortcut does.

## Installation

Build and run from a source checkout using the toolchain in [Development](docs/development.md):

```sh
./scripts/app.py build
./scripts/app.py run
```

The development bundle is `dist/dev/QuickNote.app`. For a locally packaged app, use `./scripts/app.py package` and open the resulting DMG. The app bundle is named `QuickNote.app`; its English display name is **Quick Note**.

## Usage

Press **⌃⌥N** to show the note. Press it again while the editor is focused, press Escape or close the window to hide it. The app remains in the menu bar and restores the editing position when shown again.

Click **Aa** or press **⌘⌥T** for formatting. Use native font and color panels from More. Common shortcuts include:

| Shortcut | Action |
| --- | --- |
| `⌘B`, `⌘I`, `⌘U`, `⌘⇧X` | Bold, italic, underline, strikethrough |
| `⌘K` | Add, edit or remove a link |
| `⌘\` | Clear formatting |
| `⌘⇧T`, `⌘⇧H`, `⌘⇧J`, `⌘⇧B`, `⌘⇧M` | Title, heading, subheading, body, monospaced |
| `⌘⇧7`, `⌘⇧8`, `⌘⇧9` | Bulleted, dashed, numbered list |
| `⌘'`, `⌘⇧L`, `⌘⇧U` | Quote, checklist, toggle completion |
| `⌘]`, `⌘[`, Tab, Shift+Tab | Increase or decrease list indentation |
| `⌘F`, `⌘Z`, `⌘⇧Z` | Find, undo, redo |
| `⌘⌥⇧V` | Paste and match style |

Return adds a list item; Return or Backspace in an empty item reduces indentation before returning to body text. Shift+Return adds a line within a block. Typing `* `, `- ` or `1. ` at a paragraph start creates a list. Clear Formatting affects only selected character formatting unless the selection covers whole paragraphs or only the caret is placed.

Edits save after about 350 ms of inactivity. Saving waits while an input method is composing text. Hiding, losing focus and normal quit commit pending input and save immediately. Save failures offer retry; quitting with unsaved changes asks whether to discard them.

Settings has **General**, **Appearance**, **Editing** and **Local Data** pages. General contains language, launch at login and the global shortcut. Choose **简体中文** or **English**, or use Left/Right Arrow while a language button is focused, to update the interface immediately; note content remains unchanged. Click the shortcut field and press a combination containing Command, Control or Option. Escape or leaving the window cancels recording. Recording temporarily pauses the global shortcut, and a registration conflict keeps the previous combination and saved setting. The accepted custom shortcut is restored on the next launch. Login launches stay in the menu bar.

Appearance controls Keep on Top and Follow System, Light, or Dark appearance; Editing controls spelling and link detection; Local Data shows the database location. The editor uses Liquid Glass on macOS 26 and later with a system material fallback on older versions or with Reduce Transparency enabled.

### Fn+Q

macOS Quick Note also uses Fn/Globe+Q. Disable or change that shortcut in **System Settings → Keyboard → Keyboard Shortcuts → Mission Control** before enabling Fn+Q here. This mode requires Accessibility permission; follow macOS relaunch instructions after granting it. A failed registration retains the previous shortcut. Only the target combination and its release events are consumed.

## Privacy

The page is stored at `~/Library/Application Support/QuickNote/notes.sqlite`. Schema 2 stores stable paragraph IDs, order, text, rich text, checklist states and indentation in one transaction. Unsupported schemas and damaged data are rejected without deleting or rebuilding the original database. Quit before backing up the entire data directory so the SQLite WAL is included. See [Privacy](docs/privacy.md).

## Development

Use `./scripts/app.py build`, `run`, `test`, `package` and `release --dry-run`. Open `QuickNote.xcodeproj` for native Xcode development. Storage, editing and native verification tools are described in [Development](docs/development.md).

## Contributing

See [Contributing](CONTRIBUTING.md). Maintained by [Mayflies](https://github.com/mayflies-app); optional support is available through [GitHub Sponsors](https://github.com/sponsors/nshcr).

## License

[MIT](LICENSE).
