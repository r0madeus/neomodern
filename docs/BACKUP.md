# Backup, restore and moving the music folder (decision K28)

The owner wants to move to another computer (or phone) and keep the same
experience: profiles, PINs, favourites, playlists, history and stats,
queues, settings, artist bios and pictures, lyrics and album covers. Music
files stay the user's own folders and are never part of a backup.

## 1. Export / Import (Settings › Backup)

- **Export** writes one file `NeoModern-backup-<yyyy-mm-dd-hhmm>.nmbackup`
  (a zip) to a place the user picks (desktop: save dialog; Android: the
  system "create document" picker). Contents:
  - `manifest.json`: format version 1, app version, schema version, created
    at (UTC), source platform, list of entries with sizes and SHA-256.
  - `library.sqlite3`: a consistent copy made with `VACUUM INTO` (never the
    live file; the app keeps running).
  - `session.json` (queues, pins and settings of every profile).
  - `images/playlists`, `images/albums`, `images/artists`, `lyrics`.
  - Not included: the cache (rebuilt), `tools/` (yt-dlp, ffmpeg),
    `sync-backups/`, downloaded installers, log files.
- **Import** (pick a `.nmbackup`):
  1. Validate before touching anything: zip only, manifest present, format
     and schema version not newer than this app's, every entry listed in the
     manifest with matching size and SHA-256, only the known names/folders
     above (no absolute paths, no `..`, no links), total ≤ 4 GiB, each image
     ≤ 15 MiB, entry count ≤ 200 000. `library.sqlite3` must pass
     `PRAGMA integrity_check` (opened read-only from a temp copy).
  2. Show what it contains (profiles, tracks, playlists, created at, from
     which app version) and ask "Replace all data on this device?".
  3. Copy the current data folder's same entries to
     `data/before-import-<utc>/` first (kept; the newest 3 are kept).
  4. Stage the new files in `data/import-staging/`, then the app restarts;
     on start-up, before the database is opened, the staging folder is moved
     into place (atomic renames where possible). A failed swap rolls back to
     the copy from step 3.
  5. After the restart the library rescans its folders; tracks whose files
     are not found are kept (never deleted on import), and Settings shows
     "Music folders not found" with **Move folder** for each (section 2).
- Paired devices and their keys are included (the same device id moves); a
  Jam never is. An imported device keeps its PINs.

## 2. Move a music folder (Library › Folders)

- For a folder whose path changed (another drive, another computer):
  **Move folder…** → pick the new location. The app checks that it exists
  and that at least some of the known files are found under the new path
  (shows "N of M songs found" before applying).
- Applying rewrites the folder path and every track path under it in one
  transaction, keeping track ids, so favourites, playlists, history and
  stats stay attached. Album cover paths that pointed inside the old folder
  are rewritten too. Nothing on disk is moved or changed.
- Then that folder is rescanned (new files added, missing ones handled the
  usual way). Undo is not needed: moving back is the same action.
- Safety: the scanner must not remove missing tracks of a folder whose root
  is not reachable (already the case: "walk had errors, not removing
  missing tracks"); keep and test that.

## 3. Automatic backup to a folder (cloud, way 1)

- Settings › Backup › **Automatic backup**: off by default. The user picks a
  folder (typically a OneDrive / Google Drive / Dropbox folder; the app has
  no cloud code and no accounts). Choices: every day / every week; keep the
  newest 3 / 5 / 10 (default 5).
- Runs in the background when due (checked at start-up and every hour), the
  same export as section 1, written as `*.nmbackup.partial` then renamed so
  a cloud client never uploads a half file. Old files beyond "keep" are
  deleted (only files the app named, in that folder).
- Status line: "Last backup: <time> (<size>)" or the last error. Never
  blocks the UI; never runs during a scan or an import.
- Desktop only for now (Android: manual export with the system picker).

## Rules

- All file work in Rust (`src-tauri/src/backup/`), never in the UI.
- No big payloads over IPC: commands return small status objects.
- English code, logs and comments; Turkish UI strings via i18n.
