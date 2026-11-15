# Where NeoModern keeps its files

Two kinds of files, kept apart so that clearing the cache never loses
anything the user made or had to fetch on purpose, and copying the data
folder to another computer is enough to move a library.

| Folder (Tauri name) | Windows | What | Safe to delete? |
|---|---|---|---|
| `app_data_dir` | `%APPDATA%\io.github.r0madeus.neomodern` | `library.sqlite3` (folders, playlists, favourites, listening history, tag undo history, artist bios, scan index), `session.json` (queue, settings), `images/playlists` (covers the user picked), `images/albums` (covers downloaded with "Find info"), `images/artists` (artist pictures), `lyrics` (lyrics found online) | No: this is the user's data |
| `app_cache_dir` | `%LOCALAPPDATA%\io.github.r0madeus.neomodern` | `covers` (album covers copied from tags/folders), `covers/online` (search and online-album covers), `covers/musicbrainz` (Find info previews), `updates` (downloaded installers) | Yes: everything is made again |
| `app_local_data_dir/tools` | `%LOCALAPPDATA%\io.github.r0madeus.neomodern\tools` | yt-dlp and ffmpeg downloaded by the app | Yes: "Set up automatically" downloads them again |

How the cache is rebuilt:

- **Album covers**: at start-up `Library::repair_missing_covers` finds albums
  whose cover file is gone and rescans just those tracks.
- **Search and preview covers**: downloaded again when they are shown.

Kept as data, so they are not downloaded again:

- **Downloaded album covers** ("Find info") cannot be made from the files;
  their undo record points at the file in `images/albums`.
- **Artist pictures** (one per artist, possibly hundreds after a bulk scan)
  live in `images/artists`; bios are in the database. A profile older than
  30 days is checked again, but a picture whose address did not change is not
  downloaded again.
- **Lyrics** found online (and "not found" answers, which expire after 7
  days) live in `lyrics`. Lyrics the user attaches are saved as a `.lrc` next
  to the song.

Older versions kept downloaded covers, artist pictures and lyrics in the
cache; start-up moves them over (`Library::with_user_images_dir`, `lib.rs`).

Rules for new features: anything the user creates or chooses, or that the
app fetched on purpose and cannot make again without the network, goes under
`app_data_dir`; anything derived from local files or cheap to fetch again
goes under `app_cache_dir`. The database stores file paths only as hints:
code must handle a missing file.
