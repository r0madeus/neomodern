# Large-library performance

The benchmark is
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

## Optimisation round 1 (library queries, per-profile)

The results table above is the first measurement (before profiles existed).
Once every query was per profile, the same benchmark (`NM_BENCH_SKIP_SYNC=1`
stops before the sync steps) was slower in places and one query never
finished; the "before" column is that run, "after" is the same benchmark
after this round. Median ms, 50 000 tracks, 200 000 listens, release build.

| Operation | Before | After |
|---|---:|---:|
| songs page @45000, sort artist | 170 | 5 |
| songs page @45000, sort title | 248 | 4 |
| songs page @45000, sort album | 173 | 70 |
| songs page @45000, sort duration | 229 | 4 |
| songs page @45000, sort added | 51 | 4 |
| songs page @0, any sort | 21-24 / 2.6 | 21-23 / 2-3 |
| artist directory @0 / @2000 / search | 119 / 329 / 29 | 11 / 11 / 11 |
| artist profile (prolific / median) | 362 / 356 | 39 / 36 |
| listening_stats 7 days | 2949 | 76 |
| listening_stats 30 days | 3125 | 163 |
| listening_stats 90 days | 3406 | 284 |
| listening_stats last year | 3763 | 406 |
| listening_stats this year | 4151 | 588 |
| listening_stats all time | 4892 | 901 |
| home_feed | did not finish (> 39 CPU-minutes) | 290 |
| home_mix_detail (weekly) | 51 | 28 |

What changed (all results identical, checked by `library/db_perf_tests.rs`
against the old SQL on a seeded two-profile library, order included):

- **Songs.** The page's ids are chosen first (sort + OFFSET on minimal
  columns), then rows and `plays` are computed for those 100 ids only. New
  indexes `tracks_title_artist`, `tracks_title_desc`, `tracks_duration_asc`,
  `tracks_duration_desc` let title and duration sorts read the index in
  order. A deep artist-sorted page finds the artist at the offset and the
  number of tracks before it from the `(artist, title)` index and sorts only
  the tracks from that artist on (`deep_artist_page`).
- **Artist directory.** The page of names is selected first (index-only
  scan), counts and plays are computed for those names only; new covering
  index `listen_events_profile_artist_plays`. The profile totals use
  `track_id IN (...)` instead of a per-event `EXISTS`.
- **Stats.** Range bounds are written into the SQL only when present, so the
  `(profile_id, started_at)` range is used (the `?1 IS NULL OR ...` form made
  every query scan the whole profile). The numeric parts (summary sums, hour,
  weekday, month, active days, streaks) come from one ordered pass summed per
  15-minute window, with the local offset looked up once per window instead
  of `strftime(..., 'localtime')` per event; years are found by index hops.
  Events are grouped once into a small temp table (by track id and names), and
  the track, artist, album and genre lists are aggregated from that. Path and
  cover of the few listed tracks are looked up afterwards. New covering index
  `listen_events_profile_stats` (about 15 MB at 200 000 listens).
- **Home feed.** Rediscover is set-based (it ran a full scan of the listens
  per track: minutes at this size); recently played tracks and albums walk
  the newest plays and stop at the limit; the weekly, on-repeat and focus
  mixes aggregate events by track id from the covering index (events whose
  id was lost are resolved by path in a second select) and load track rows,
  with `plays`, only for the final handful.

Not reached: the 90-day stats (284 ms, target 150), all-time stats (901 ms,
target 300) and the album-sorted deep songs page (70 ms, target 60). What is
left in stats is the grouping of 50 000+ (track, name) groups in SQLite's
temp b-trees for the all-time range; going lower needs the grouping done in
one Rust pass over the covering index, or per-day summary rows kept up to
date (a schema change). Album sort needs the album columns in the sort key;
a boundary trick like the artist one, or a denormalised sort key, would do it.
The benchmark's listens are inserted in random time order, so index-order
reads of the old non-covering indexes were random I/O; real histories are
mostly chronological and were cheaper than measured here.

## Slow spots still open

1. **Sync rounds are heavy even when idle: ~0.6 s every round.**
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
