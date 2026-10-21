# Privacy

## Local Data

The note is stored at `~/Library/Application Support/QuickNote/notes.sqlite`. Schema 2 contains one note and ordered paragraph blocks with stable UUIDs, plain text, RTF, checklist states and indentation. Preferences use macOS user defaults under `app.mayfiles.QuickNote`.

The whole page is saved in one SQLite transaction with WAL and FULL synchronization. Unsupported schemas and damaged records produce an error without deleting or silently recreating the database.

The database is local plaintext, not encrypted storage. Protect it and its backups as personal content. Quit before copying the complete data directory; copying only the SQLite file while the app runs can omit changes in the WAL.

### Removing Data

Quit and back up the complete data directory before removing the app. Removing the bundle does not delete the note. Removing `~/Library/Application Support/QuickNote/` deletes the saved page.

## Network Access

Quick Note requires no account, model service or network connection. It has no telemetry, cloud sync or project-operated server. Opening a link uses the system browser or app.

## Permissions

The default Carbon global shortcut requires no Accessibility permission. Optional Fn+Q uses a keyboard event filter and requires Accessibility. It consumes only the target combination and release events. Disable the conflicting macOS Quick Note shortcut before enabling it.

Launch at Login uses macOS Login Items and can require approval. System permission dialogs follow the macOS language independently of the app language.
