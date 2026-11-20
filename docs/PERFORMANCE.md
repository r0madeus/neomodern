# Large-library performance

Measurement only: nothing here has been optimised yet. The benchmark is
`src-tauri/src/library/large_library.rs` (ignored by default).

## Run it

```bash
cd src-tauri
cargo test --release --lib large_library -- --ignored --nocapture
# quick smoke run: NM_BENCH_SCALE=0.1   (all counts scaled)
# rescan size:     NM_BENCH_FILES=3000
# keep temp dir:   NM_BENCH_KEEP=1
```

It takes about 2 minutes and needs ~1 GB of temp space. Dataset: 50 000
tracks, 4 000 albums, 2 500 artists (about 15 % compound), 40 genres, 200
playlists x 100, 2 000 favourites, 200 000 listen events over 2 years, built
through the real schema (`Library::open`). It runs no `ANALYZE`, like the app.
"Cold" is the first call on a freshly reopened library (empty SQLite caches,
warm OS cache); "median" is of 5 further runs.

## Machine

4 cores, Intel Xeon Processor @ 2.10GHz (cloud VM). Expect a desktop to be
roughly 2x faster; the ratios are what matter.

## Results (ms)

| Operation | Cold | Median |
|---|---:|---:|
| songs page @0, sort artist / title / album / duration | 22-24 | 21-29 |
| songs page @0, sort added | 2.8 | 2.4 |
| songs page @45000, sort artist | 183 | 170 |
| songs page @45000, sort title | 273 | 232 |
| songs page @45000, sort album | 171 | 169 |
| songs page @45000, sort duration | 225 | 227 |
| songs page @45000, sort added | 53 | 53 |
| search songs, 1-3 tokens, common or rare | 22-34 | 23-37 |
| search albums, 1 token | 36 | 34 |
| search albums, 2 tokens | 74 | 76 |
| albums page @0 / @3900 | 1.6 / 7.7 | 1.3 / 6.5 |
| album detail | 0.3 | 0.1 |
| artist directory @0 | 107 | 118 |
| artist directory @2000 | 329 | 341 |
| artist directory search | 33 | 31 |
| artist profile (prolific / median) | 122 / 116 | 123 / 114 |
| genre list | 59 | 62 |
| genre detail / page @0 / page @1000 | 28 / 24 / 42 | 35 / 25 / 33 |
| listening_stats, last 7 days | 423 | 379 |
| listening_stats, last 30 days | 610 | 616 |
| listening_stats, 90 days | 997 | 970 |
| listening_stats, last year | 1325 | 1354 |
| listening_stats, this year | 1818 | 1890 |
| listening_stats, all time | 3093 | 3104 |
| home_feed | 2142 | 2094 |
| home_mix_detail | 54 | 51 |
| playlists list (200) | 44 | 43 |
| playlist page / favourites page / favourite ids | 0.9 / 9.5 / 3.7 | 0.4 / 9.1 / 3.3 |
| library_stats | 0.4 | 0.01 |
| play all: all_tracks (artist / title) | 123 / 113 | 116 / 95 |
| play search: matching_tracks | 87 | 92 |
| play genre | 66 | 67 |
| play album / playlist / favourites / artist | < 4 | < 4 |
| sync Resolver::load | 212 | 200 |
| sync capture, first (222 140 rows stamped) | 2266 | - |
| sync capture, idle | 617 | 585 |
| sync apply, empty batch (idle round) | 760 | 618 |
| sync plan, 1 005 changes | 622 | - |
| sync apply, 1 005 changes | 950 | - |
| sync apply, same batch again | 911 | 918 |
| sync quick_check | 273 | 278 |
| sync backup_if_due (VACUUM INTO) | 608 | 632 |
| rescan 3 000 files, first scan | 109 | - |
| rescan 3 000 files, nothing changed | 7.4 | 6.1 |

Database file: 102 MB after generation, 167 MB after the sync steps (sync
tables duplicate the listens); one backup is 160 MB, 5 are kept (~0.8 GB).

Rescan: 0.036 ms/file first scan, 0.002 ms/file unchanged, so about 1.8 s and
0.1 s for 50 000 files. Caveat: tiny files in a warm OS cache; a real library
on a cold disk or network share will be dominated by `stat` and tag reads.

## Slow spots and proposed fixes

UI waits above 100 ms, background work above 1 s. Causes marked "likely" were
inferred from the SQL and plans, not profiled.

1. **Stats view, 0.4-3.1 s** (`listening_stats`, grows with the period).
   It runs ~10 aggregate queries over `listen_events`, each with
   `(?1 IS NULL OR started_at >= ?1)` (SQLite cannot use the `started_at`
   index for an `OR ?param IS NULL` range, likely) and
   `GROUP BY LOWER(title), LOWER(artist)` (temp B-tree), plus `streak_stats`
   with `julianday()` per row. Fix: build the SQL with the range bounds only
   when present (or use `COALESCE(?1, -1<<62)` bounds) so the index range is
   used; group by `track_id` where set; compute streak days from
   `SELECT DISTINCT started_at / 86400` buckets. Optionally cache the result
   per library version.
2. **Home feed 2.1 s** on every Home open. Four mix queries plus recent
   lists over `listen_events` (mix detail alone is ~50 ms, so the feed does
   far more than four mixes' worth, likely repeated recent/"rediscover"
   scans). Fix: load the lists lazily or in parallel, cache by library
   version, and make the mix count queries cheap (count only, no track
   rows).
3. **Artist directory 110 ms at the top, 340 ms deep.** Plan: `SCAN ta USING
   COVERING INDEX track_artists_artist`, two `count(DISTINCT)` temp
   B-trees, `ORDER BY` temp B-tree, and two correlated `listen_events`
   scans per artist group (`artist = ... COLLATE NOCASE`). The whole
   `track_artists` table is grouped before `LIMIT`. Fix: page the artist
   names first (`SELECT DISTINCT artist ... LIMIT/OFFSET`), then compute
   counts and plays only for those 100 names; or keep an `artists` summary
   table updated at scan time. The artist profile (~120 ms) has the same
   per-artist event scans.
4. **Songs, deep pages 170-270 ms** (offset 45 000), and sort by duration.
   Plans: `SCAN t USING INDEX idx_tracks_album_added` + `USE TEMP B-TREE FOR
   ORDER BY` (album, duration), `SCAN t USING INDEX tracks_added` (added).
   OFFSET walks and the `plays` subqueries run for skipped rows, and
   several sorts lack a matching index (`LEFT JOIN albums` plus
   `COLLATE NOCASE` columns). Fix: keyset pagination (remember the last sort
   key), or select ids first in a subquery and compute `plays` only for the
   100 returned rows; add an index on `duration_ms`.
5. **Sync rounds are heavy even when idle: ~0.6 s every round.**
   `Resolver::load` (200 ms, loads all 50 000 tracks and builds keys) runs in
   every `capture`, `plan` and `apply` (apply with a backup runs it three
   times); idle capture is 585 ms, `plan` 620 ms. The first capture is
   2.3 s and stamps 222 140 rows (listens are copied into `sync_listens`,
   +65 MB). `apply` also runs `quick_check` (275 ms) whenever data changed,
   and `backup_if_due` 0.6 s plus 160 MB per backup. All of this holds the
   library lock. Fix: skip capture when no local table changed (a dirty flag
   or `PRAGMA data_version`), keep a cached `Resolver` per library version,
   run `plan` and `apply` from one `Resolver`, and run the first capture in
   chunks off the lock.

Smaller: `all_tracks` / `matching_tracks` for play-all take ~100 ms for 50 000
rows (queue replace on top of that), the album search with 2+ tokens is 75 ms
(correlated `EXISTS` over tracks per token; `SCAN a` + temp B-tree), the
genre list is 60 ms (full `GROUP BY LOWER(TRIM(genre))`), playlists sidebar
43 ms. Plain `LIKE '%x%'` search stays 20-37 ms, fine at this size. The
no-change rescan is cheap.
