# Where NeoModern keeps its files

Two kinds of files, kept apart so that clearing the cache never loses
anything the user made, and copying the data folder to another computer
is enough to move a library.

| Folder (Tauri name) | Windows | What | Safe to delete? |
|---|---|---|---|
| `app_data_dir` | `%APPDATA%\io.github.r0madeus.neomodern` | `library.sqlite3` (folders, playlists, favourites, listening history, tag undo history, scan index), `session.json` (queue, settings), `images/playlists` (covers the user picked) | No: this is the user's data |
| `app_cache_dir` | `%LOCALAPPDATA%\io.github.r0madeus.neomodern` | `covers` (album covers from tags/folders), `covers/online` (artist portraits, search covers), `lyrics` (lyrics cache) | Yes: everything is made again |
| `app_local_data_dir/tools` | `%LOCALAPPDATA%\io.github.r0madeus.neomodern\tools` | yt-dlp and ffmpeg downloaded by the app | Yes: "Set up automatically" downloads them again |

How the cache is rebuilt:

- **Album covers**: at start-up `Library::repair_missing_covers` finds albums
  whose cover file is gone and rescans just those tracks.
- **Artist portraits and bios**: a profile whose image file is missing is
  fetched again (with the "Artist profiles" switch on); bios expire after
  30 days.
- **Lyrics**: found again from the file, a sidecar `.lrc` or online.

Rules for new features: anything the user creates or chooses goes under
`app_data_dir`; anything fetched or derived goes under `app_cache_dir`. The
database stores cache paths only as hints: code must handle a missing file.
