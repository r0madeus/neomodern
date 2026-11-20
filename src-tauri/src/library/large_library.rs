//! Large-library benchmark (not a correctness test; `#[ignore]`d).
//!
//! ```text
//! cd src-tauri
//! cargo test --release --lib large_library -- --ignored --nocapture
//! ```
//!
//! Builds a synthetic library through the real schema (about 50 000 tracks,
//! 4 000 albums, 2 500 artists, 200 000 listen events, ...), then times the
//! queries behind the main screens, the sync store and a no-change rescan.
//! Results are printed as a markdown table; see `docs/PERFORMANCE.md`.
//!
//! Environment knobs: `NM_BENCH_SCALE` (default `1.0`) scales every count,
//! e.g. `0.1` for a quick smoke run. `NM_BENCH_KEEP=1` prints the temp dir
//! and keeps it.

use super::db::{self, SortDir, SortOrder, SortSpec};
use super::scan::scan_folder;
use super::{Hooks, Library, ProfileId};
use crate::sync::store::{self, ApplyOptions, Batch};
use lofty::config::WriteOptions;
use lofty::prelude::*;
use lofty::tag::{Tag, TagType};
use rusqlite::{Connection, params};
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------
// Tiny deterministic RNG
// ---------------------------------------------------------------------

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
    /// Index in `0..n`, biased towards 0 (`p` > 1 = stronger bias).
    fn skew(&mut self, n: usize, p: f64) -> usize {
        (((self.unit().powf(p)) * n as f64) as usize).min(n - 1)
    }
}

// ---------------------------------------------------------------------
// Vocabulary
// ---------------------------------------------------------------------

const EN: &[&str] = &[
    "love",
    "night",
    "the",
    "blue",
    "heart",
    "dream",
    "fire",
    "day",
    "time",
    "road",
    "light",
    "dance",
    "rain",
    "sun",
    "moon",
    "star",
    "river",
    "home",
    "gold",
    "wild",
    "city",
    "summer",
    "winter",
    "ghost",
    "ocean",
    "paper",
    "glass",
    "silver",
    "shadow",
    "morning",
    "angel",
    "storm",
    "mirror",
    "garden",
    "memory",
    "highway",
    "silence",
    "thunder",
    "velvet",
    "echo",
    "island",
    "midnight",
    "diamond",
    "empire",
    "whisper",
    "carousel",
    "horizon",
    "lullaby",
    "serenade",
    "paradise",
    "runaway",
    "kingdom",
    "machine",
    "railroad",
    "sunrise",
    "sunset",
    "butterfly",
];

const SYLLABLES: &[&str] = &[
    "ka", "lo", "mi", "ra", "te", "su", "no", "vi", "da", "po", "ne", "zu", "ba", "li", "mo", "xe",
    "tu", "fa", "gi", "he",
];

const FIRST: &[&str] = &[
    "Ayşe", "Gökhan", "Şebnem", "Çağla", "Ömer", "Işıl", "Barış", "Yuki", "Haruka", "Kenji", "Mei",
    "Aiko", "John", "Maria", "Nina", "Miles", "Björk", "Tom", "Sara", "Luca", "Elena", "Marcus",
    "Olivia", "Hugo", "Clara", "Felix", "Ingrid", "Jonas", "Katya", "Leon", "Mona", "Nils",
    "Oscar", "Petra", "Quincy", "Rosa", "Stefan", "Tina", "Ugo", "Vera", "Wim", "Xenia", "Yara",
    "Zeki", "Anna", "Boris", "Chloe", "Dario", "Eva", "Fritz", "Gina", "Hans", "Iris", "Jack",
    "Kira", "Lena", "Max", "Nora", "Otto", "Pia", "Rex",
];

const LAST: &[&str] = &[
    "Yılmaz",
    "Öztürk",
    "Çelik",
    "Şahin",
    "Doğan",
    "Kaya",
    "Demir",
    "Tanaka",
    "Sato",
    "Suzuki",
    "Watanabe",
    "Ito",
    "Smith",
    "Jones",
    "Brown",
    "Davis",
    "Miller",
    "Wilson",
    "Moore",
    "Taylor",
    "Anderson",
    "Thomas",
    "Jackson",
    "White",
    "Harris",
    "Martin",
    "Thompson",
    "Garcia",
    "Martinez",
    "Robinson",
    "Clark",
    "Rodriguez",
    "Lewis",
    "Lee",
    "Walker",
    "Hall",
    "Allen",
    "Young",
    "King",
    "Wright",
    "Scott",
    "Green",
    "Baker",
    "Adams",
    "Nelson",
    "Hill",
    "Campbell",
    "Mitchell",
    "Roberts",
    "Carter",
    "Phillips",
    "Evans",
    "Turner",
    "Torres",
    "Parker",
    "Collins",
    "Edwards",
    "Stewart",
    "Morris",
    "Murphy",
];

const GENRES: [&str; 40] = [
    "Rock",
    "Pop",
    "Jazz",
    "Blues",
    "Classical",
    "Electronic",
    "Hip-Hop",
    "Folk",
    "Metal",
    "Punk",
    "Soul",
    "Funk",
    "Reggae",
    "Country",
    "Ambient",
    "Techno",
    "House",
    "Disco",
    "Indie",
    "Alternative",
    "R&B",
    "Soundtrack",
    "Latin",
    "World",
    "Turkish Pop",
    "Arabesk",
    "J-Pop",
    "Shoegaze",
    "Post-Rock",
    "Trip-Hop",
    "Gospel",
    "Opera",
    "Swing",
    "Bossa Nova",
    "Synthwave",
    "Lo-Fi",
    "Drum and Bass",
    "Dub",
    "Grunge",
    "Psychedelic",
];

const TR_TITLES: &[&str] = &[
    "Gönlümün Sultanı",
    "İstanbul'da Yağmur",
    "Şu Çocukluk Günleri",
    "Çok Uzaklarda",
    "Ağlama Yar",
    "Yüreğim Sızlıyor",
];
const JA_TITLES: &[&str] = &[
    "夜に駆ける",
    "桜の季節",
    "君の名は",
    "海の見える街",
    "星空のメロディ",
];

fn cap(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

struct Vocab(Vec<String>);

impl Vocab {
    fn new() -> Self {
        let mut v: Vec<String> = EN.iter().map(|s| (*s).to_owned()).collect();
        for a in SYLLABLES {
            for b in SYLLABLES {
                v.push(format!("{a}{b}"));
            }
        }
        Self(v)
    }
    fn phrase(&self, rng: &mut Rng, words: usize) -> String {
        let parts: Vec<String> = (0..words)
            .map(|i| {
                let w = &self.0[rng.skew(self.0.len(), 2.5)];
                if i == 0 { cap(w) } else { w.clone() }
            })
            .collect();
        parts.join(" ")
    }
}

// ---------------------------------------------------------------------
// Dataset
// ---------------------------------------------------------------------

#[derive(Clone, Copy)]
struct Scale {
    tracks: usize,
    albums: usize,
    artists: usize,
    playlists: usize,
    per_playlist: usize,
    favorites: usize,
    listens: usize,
}

impl Scale {
    fn from_env() -> Self {
        let f: f64 = std::env::var("NM_BENCH_SCALE")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1.0);
        let s = |n: f64| ((n * f) as usize).max(10);
        Self {
            tracks: s(50_000.0),
            albums: s(4_000.0),
            artists: s(2_500.0).min(FIRST.len() * LAST.len()),
            playlists: s(200.0),
            per_playlist: 100,
            favorites: s(2_000.0),
            listens: s(200_000.0),
        }
    }
}

struct TrackMeta {
    id: i64,
    path: String,
    title: String,
    artist: String,
    album: String,
    genre: &'static str,
    duration_ms: i64,
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Fills an empty, freshly initialised database. Returns per-track metadata
/// (used for listens and the second sync device).
fn generate(conn: &mut Connection, sc: Scale) -> Vec<TrackMeta> {
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    let vocab = Vocab::new();
    let now = now_secs();
    let two_years = 2 * 365 * 86_400;

    let artists: Vec<String> = (0..sc.artists)
        .map(|i| format!("{} {}", FIRST[i % FIRST.len()], LAST[i / FIRST.len()]))
        .collect();

    let tx = conn.transaction().unwrap();
    tx.execute("INSERT INTO folders(id, path) VALUES (1, '/music')", [])
        .unwrap();

    // Albums: the first `artists` albums give every artist one, the rest
    // are skewed towards prolific artists.
    let mut album_meta: Vec<(String, usize, &'static str, i64, i64)> = Vec::new();
    {
        let mut ins = tx
            .prepare(
                "INSERT INTO albums(id, title, album_artist, year, cover)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )
            .unwrap();
        let mut seen = std::collections::HashSet::new();
        for i in 0..sc.albums {
            let artist = if i < sc.artists {
                i
            } else {
                rng.skew(sc.artists, 1.8)
            };
            let words = 1 + rng.below(3);
            let mut title = vocab.phrase(&mut rng, words);
            if !seen.insert((title.clone(), artist)) {
                title = format!("{title} {i}");
                seen.insert((title.clone(), artist));
            }
            let year = 1970 + rng.below(56) as i64;
            let cover = (rng.below(10) != 0).then(|| format!("/cache/covers/{i:016x}.jpg"));
            ins.execute(params![i as i64 + 1, title, artists[artist], year, cover])
                .unwrap();
            let genre = GENRES[rng.skew(GENRES.len(), 1.6)];
            let added = now - rng.below(two_years) as i64;
            album_meta.push((title, artist, genre, year, added));
        }
    }

    // Tracks.
    let mut metas = Vec::with_capacity(sc.tracks);
    {
        let mut ins = tx
            .prepare(
                "INSERT INTO tracks(id, folder_id, path, mtime, size, title, artist, album_id,
                                    track_no, disc_no, year, duration_ms, genre, added_at)
                 VALUES (?1, 1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            )
            .unwrap();
        for i in 0..sc.tracks {
            let album_idx = i % sc.albums;
            let (album_title, artist_idx, genre, year, added) = &album_meta[album_idx];
            let track_no = (i / sc.albums) as i64 + 1;
            let title = if i % 20 == 3 {
                format!("{} {}", TR_TITLES[rng.below(TR_TITLES.len())], i % 97)
            } else if i % 25 == 7 {
                format!("{} {}", JA_TITLES[rng.below(JA_TITLES.len())], i % 89)
            } else if i % 17_000 == 5 {
                "Zzyzx Road".to_owned() // rare search word, 3 hits at full scale
            } else {
                let n = if rng.below(10) == 0 {
                    5 + rng.below(4)
                } else {
                    1 + rng.below(4)
                };
                vocab.phrase(&mut rng, n)
            };
            let base = &artists[*artist_idx];
            let r = rng.below(100);
            let partner = &artists[rng.skew(sc.artists, 1.5)];
            let artist = match r {
                0..=9 => format!("{base} feat. {partner}"),
                10..=12 => format!("{base}, {partner}"),
                13..=14 => format!("{base} & {partner}"),
                _ => base.clone(),
            };
            let path = format!("/music/{base}/{album_title}/{track_no:02} - {title}.flac");
            let duration_ms = 90_000 + rng.below(330_000) as i64;
            let id = i as i64 + 1;
            ins.execute(params![
                id,
                path,
                added,
                20_000_000 + rng.below(30_000_000) as i64,
                title,
                artist,
                album_idx as i64 + 1,
                track_no,
                1,
                year,
                duration_ms,
                genre,
                added,
            ])
            .unwrap();
            // Same call the scanner makes after writing a track.
            db::sync_track_artists(&tx, id, &artist).unwrap();
            metas.push(TrackMeta {
                id,
                path,
                title,
                artist,
                album: album_title.clone(),
                genre,
                duration_ms,
            });
        }
    }

    // Listen events: skewed towards a favourite core, recent-heavy.
    {
        let mut ins = tx
            .prepare(
                "INSERT INTO listen_events(track_id, path, title, artist, album, genre,
                                          duration_ms, started_at, ended_at, listened_ms,
                                          completed, skipped, uid)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            )
            .unwrap();
        for i in 0..sc.listens {
            let m = &metas[rng.skew(metas.len(), 2.5)];
            let started = now - (rng.unit().powf(1.5) * two_years as f64) as i64;
            let completed = rng.below(10) < 7;
            let listened = if completed {
                m.duration_ms
            } else {
                3_000 + rng.below(60_000) as i64
            };
            // 2 % are "unlinked" (track id lost), matched by path.
            let track_id = (rng.below(50) != 0).then_some(m.id);
            ins.execute(params![
                track_id,
                m.path,
                m.title,
                m.artist,
                m.album,
                m.genre,
                m.duration_ms,
                started,
                started + listened / 1000,
                listened,
                i64::from(completed),
                i64::from(!completed && listened < 30_000),
                format!("{:016x}{:016x}", rng.next(), i as u64),
            ])
            .unwrap();
        }
    }

    // Playlists and favourites.
    {
        let mut pl = tx
            .prepare("INSERT INTO playlists(id, name, created_at) VALUES (?1, ?2, ?3)")
            .unwrap();
        let mut pt = tx
            .prepare(
                "INSERT INTO playlist_tracks(playlist_id, position, track_id, added_at)
                 VALUES (?1, ?2, ?3, ?4)",
            )
            .unwrap();
        for p in 0..sc.playlists {
            let created = now - rng.below(two_years) as i64;
            pl.execute(params![
                p as i64 + 1,
                format!("Playlist {p} {}", vocab.phrase(&mut rng, 2)),
                created
            ])
            .unwrap();
            for pos in 0..sc.per_playlist {
                let t = &metas[rng.below(metas.len())];
                pt.execute(params![p as i64 + 1, pos as i64, t.id, created])
                    .unwrap();
            }
        }
        let mut fav = tx
            .prepare("INSERT OR IGNORE INTO favorites(profile_id, track_id, added_at) VALUES (1, ?1, ?2)")
            .unwrap();
        for _ in 0..sc.favorites {
            let t = &metas[rng.skew(metas.len(), 1.5)];
            fav.execute(params![t.id, now - rng.below(two_years) as i64])
                .unwrap();
        }
    }
    tx.commit().unwrap();
    metas
}

// ---------------------------------------------------------------------
// Timing helpers
// ---------------------------------------------------------------------

struct Row {
    group: &'static str,
    name: String,
    cold: Duration,
    median: Option<Duration>,
}

#[derive(Default)]
struct Report {
    rows: Vec<Row>,
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn fmt_ms(v: f64) -> String {
    if v >= 100.0 {
        format!("{v:.0}")
    } else if v >= 10.0 {
        format!("{v:.1}")
    } else {
        format!("{v:.2}")
    }
}

impl Report {
    /// First run is "cold" (fresh connection, no cached statements), then
    /// the median of five more runs.
    fn bench<T>(&mut self, group: &'static str, name: &str, mut f: impl FnMut() -> T) {
        let t = Instant::now();
        std::hint::black_box(f());
        let cold = t.elapsed();
        let mut runs: Vec<Duration> = (0..5)
            .map(|_| {
                let t = Instant::now();
                std::hint::black_box(f());
                t.elapsed()
            })
            .collect();
        runs.sort();
        let median = runs[2];
        println!(
            "{group:<8} {name:<46} cold {:>9} ms  median {:>9} ms",
            fmt_ms(ms(cold)),
            fmt_ms(ms(median))
        );
        self.rows.push(Row {
            group,
            name: name.to_owned(),
            cold,
            median: Some(median),
        });
    }

    /// One-shot operation (changes state, cannot be repeated).
    fn once<T>(&mut self, group: &'static str, name: &str, f: impl FnOnce() -> T) -> T {
        let t = Instant::now();
        let out = f();
        let cold = t.elapsed();
        println!("{group:<8} {name:<46} once {:>9} ms", fmt_ms(ms(cold)));
        self.rows.push(Row {
            group,
            name: name.to_owned(),
            cold,
            median: None,
        });
        out
    }

    fn print_table(&self) {
        println!("\n| Group | Operation | Cold (ms) | Median (ms) |");
        println!("|---|---|---:|---:|");
        for r in &self.rows {
            println!(
                "| {} | {} | {} | {} |",
                r.group,
                r.name,
                fmt_ms(ms(r.cold)),
                r.median.map_or("-".to_owned(), |m| fmt_ms(ms(m)))
            );
        }
    }
}

/// `EXPLAIN QUERY PLAN` lines that show a scan or a temp B-tree.
fn explain(conn: &Connection, label: &str, sql: &str) {
    let Ok(mut st) = conn.prepare(&format!("EXPLAIN QUERY PLAN {sql}")) else {
        println!("    [plan {label}] could not prepare");
        return;
    };
    let lines: Vec<String> = st
        .query_map([], |r| r.get::<_, String>(3))
        .unwrap()
        .filter_map(|l| l.ok())
        .collect();
    let bad: Vec<&String> = lines
        .iter()
        .filter(|l| l.contains("SCAN") || l.contains("TEMP B-TREE"))
        .collect();
    if bad.is_empty() {
        println!("    [plan {label}] indexed ({} steps)", lines.len());
    }
    for l in bad {
        println!("    [plan {label}] {l}");
    }
}

const TRACK_COLS: &str = "SELECT t.id, t.title, t.artist, COALESCE(a.title, ''), t.album_id,
        t.track_no, t.disc_no, t.year, t.duration_ms, t.path, a.cover,
        ((SELECT COUNT(*) FROM listen_events le
           WHERE le.track_id = t.id
             AND (le.completed = 1 OR le.listened_ms >= 15000))
         + (SELECT COUNT(*) FROM listen_events le
           WHERE le.track_id IS NULL AND le.path = t.path
             AND (le.completed = 1 OR le.listened_ms >= 15000))) AS plays
        FROM tracks t LEFT JOIN albums a ON a.id = t.album_id";

fn order_by(order: SortOrder) -> &'static str {
    match order {
        SortOrder::Artist => {
            "t.artist DESC, a.title, a.year, a.id, t.disc_no, t.track_no, t.title, t.id"
        }
        SortOrder::Title => "t.title, t.artist, t.id",
        SortOrder::Album => {
            "a.title, a.album_artist, a.year, a.id, t.disc_no, t.track_no, t.title, t.id"
        }
        SortOrder::Added => "t.added_at DESC, t.id",
        SortOrder::Duration => "t.duration_ms IS NULL, t.duration_ms DESC, t.title, t.id",
    }
}

fn like_where(tokens: &[&str]) -> String {
    let parts: Vec<String> = tokens
        .iter()
        .map(|t| {
            format!(
                "(t.title LIKE '%{t}%' ESCAPE '\\' OR t.artist LIKE '%{t}%' ESCAPE '\\' \
                 OR COALESCE(a.title, '') LIKE '%{t}%' ESCAPE '\\')"
            )
        })
        .collect();
    format!("WHERE {}", parts.join(" AND "))
}

fn cpu_model() -> String {
    std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("model name"))
                .and_then(|l| l.split(':').nth(1))
                .map(|m| m.trim().to_owned())
        })
        .unwrap_or_else(|| "unknown".into())
}

fn file_mb(p: &Path) -> f64 {
    std::fs::metadata(p).map_or(0.0, |m| m.len() as f64 / 1_048_576.0)
}

// ---------------------------------------------------------------------
// The benchmark
// ---------------------------------------------------------------------

#[test]
#[ignore = "benchmark: run with --release --ignored --nocapture"]
fn large_library_benchmark() {
    let sc = Scale::from_env();
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("data/library.sqlite3");
    let covers = tmp.path().join("cache/covers");
    println!(
        "\nmachine: {} cores, {}",
        std::thread::available_parallelism().map_or(0, |n| n.get()),
        cpu_model()
    );
    println!(
        "scale: {} tracks, {} albums, {} artists, {} playlists x {}, {} favourites, {} listens",
        sc.tracks, sc.albums, sc.artists, sc.playlists, sc.per_playlist, sc.favorites, sc.listens
    );

    // --- build ---------------------------------------------------------
    let t = Instant::now();
    let metas = {
        let lib = Library::open(&db_path, &covers, Hooks::none()).unwrap();
        let mut conn = lib.conn();
        let metas = generate(&mut conn, sc);
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
            .unwrap();
        metas
    };
    println!("generated in {:.1} s", t.elapsed().as_secs_f64());
    let size_before_sync = file_mb(&db_path);

    // Reopen: empty SQLite page/statement caches, like an app start.
    let lib = Library::open(&db_path, &covers, Hooks::none()).unwrap();
    let mut rep = Report::default();
    let now = now_secs();

    // --- songs ---------------------------------------------------------
    let deep = (sc.tracks as u64).saturating_sub(5_000);
    for (label, order) in [
        ("artist", SortOrder::Artist),
        ("title", SortOrder::Title),
        ("album", SortOrder::Album),
        ("added", SortOrder::Added),
        ("duration", SortOrder::Duration),
    ] {
        let spec = SortSpec::new(order, order.default_dir());
        rep.bench("songs", &format!("page 100 @0, sort {label}"), || {
            lib.tracks_page(0, 100, spec).unwrap()
        });
        let name = format!("page 100 @{deep}, sort {label}");
        rep.bench("songs", &name, || lib.tracks_page(deep, 100, spec).unwrap());
        if ms(rep.rows.last().unwrap().median.unwrap()) > 50.0 {
            let c = lib.conn();
            explain(
                &c,
                &name,
                &format!(
                    "{TRACK_COLS} ORDER BY {} LIMIT 100 OFFSET {deep}",
                    order_by(order)
                ),
            );
        }
    }
    // Descending artist, the other direction of the default sort.
    let asc = SortSpec::new(SortOrder::Artist, SortDir::Asc);
    rep.bench("songs", "page 100 @0, sort artist asc", || {
        lib.tracks_page(0, 100, asc).unwrap()
    });

    // --- search --------------------------------------------------------
    let queries: [(&str, &[&str]); 6] = [
        ("1 token common (love)", &["love"]),
        ("1 token rare (zzyzx)", &["zzyzx"]),
        ("2 tokens common (love night)", &["love", "night"]),
        ("2 tokens rare+common (zzyzx love)", &["zzyzx", "love"]),
        (
            "3 tokens common (the love night)",
            &["the", "love", "night"],
        ),
        ("3 tokens rare (zzyzx the love)", &["zzyzx", "the", "love"]),
    ];
    for (label, toks) in queries {
        let q = toks.join(" ");
        let name = format!("search songs, {label}");
        rep.bench("search", &name, || {
            lib.search_tracks_page(0, 100, SortOrder::Artist, &q)
                .unwrap()
        });
        if ms(rep.rows.last().unwrap().median.unwrap()) > 50.0 {
            let c = lib.conn();
            explain(
                &c,
                &name,
                &format!(
                    "{TRACK_COLS} {} ORDER BY {} LIMIT 100 OFFSET 0",
                    like_where(toks),
                    order_by(SortOrder::Artist)
                ),
            );
        }
    }
    rep.bench("search", "search songs, Turkish token (gönül)", || {
        lib.search_tracks_page(0, 100, SortOrder::Artist, "gönül")
            .unwrap()
    });
    rep.bench("search", "search albums, 1 token common (love)", || {
        lib.search_albums_page(0, 100, "love").unwrap()
    });
    {
        let name = "search albums, 2 tokens (love night)";
        rep.bench("search", name, || {
            lib.search_albums_page(0, 100, "love night").unwrap()
        });
        if ms(rep.rows.last().unwrap().median.unwrap()) > 50.0 {
            let c = lib.conn();
            let w = |t: &str| {
                format!(
                    "(a.title LIKE '%{t}%' OR a.album_artist LIKE '%{t}%' OR EXISTS \
                     (SELECT 1 FROM tracks t WHERE t.album_id = a.id AND \
                     (t.title LIKE '%{t}%' OR t.artist LIKE '%{t}%')))"
                )
            };
            explain(
                &c,
                name,
                &format!(
                    "SELECT a.id, (SELECT COUNT(*) FROM tracks WHERE album_id = a.id) FROM albums a \
                     WHERE {} AND {} ORDER BY a.album_artist, a.title, a.year, a.id LIMIT 100",
                    w("love"),
                    w("night")
                ),
            );
        }
    }

    // --- albums --------------------------------------------------------
    let mid_album = (sc.albums / 2) as i64;
    rep.bench("albums", "albums page 100 @0", || {
        lib.albums_page(0, 100).unwrap()
    });
    {
        let off = (sc.albums as u64).saturating_sub(100);
        rep.bench("albums", &format!("albums page 100 @{off}"), || {
            lib.albums_page(off, 100).unwrap()
        });
    }
    rep.bench("albums", "album detail (tracks of one album)", || {
        lib.album(mid_album).unwrap()
    });

    // --- artists -------------------------------------------------------
    {
        let name = "artist directory page 100 @0";
        rep.bench("artists", name, || {
            lib.search_artists_page(0, 100, "").unwrap()
        });
        if ms(rep.rows.last().unwrap().median.unwrap()) > 50.0 {
            let c = lib.conn();
            explain(
                &c,
                name,
                "SELECT MIN(ta.artist), COUNT(DISTINCT ta.track_id), COUNT(DISTINCT t.album_id),
                        COALESCE(MAX(am.image), MAX(a.cover)),
                        COALESCE((SELECT SUM(CASE WHEN e.completed = 1 OR e.listened_ms >= 15000 THEN 1 ELSE 0 END)
                                  FROM listen_events e WHERE e.artist = ta.artist COLLATE NOCASE), 0),
                        COALESCE((SELECT SUM(e.listened_ms) FROM listen_events e
                                  WHERE e.artist = ta.artist COLLATE NOCASE), 0)
                 FROM track_artists ta JOIN tracks t ON t.id = ta.track_id
                 LEFT JOIN albums a ON a.id = t.album_id
                 LEFT JOIN artists_meta am ON am.name_key = ta.artist
                 GROUP BY ta.artist ORDER BY MIN(ta.artist) COLLATE NOCASE LIMIT 100 OFFSET 0",
            );
        }
    }
    rep.bench("artists", "artist directory page 100 @2000", || {
        lib.search_artists_page(2_000.min(sc.artists as u64 - 1), 100, "")
            .unwrap()
    });
    rep.bench("artists", "artist directory search (an)", || {
        lib.search_artists_page(0, 100, "an").unwrap()
    });
    let (top_artist, mid_artist): (String, String) = {
        let c = lib.conn();
        let top = c
            .query_row(
                "SELECT artist FROM track_artists GROUP BY artist ORDER BY COUNT(*) DESC LIMIT 1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let mid = c
            .query_row(
                "SELECT artist FROM track_artists GROUP BY artist ORDER BY COUNT(*) DESC
                 LIMIT 1 OFFSET ?1",
                [sc.artists as i64 / 2],
                |r| r.get(0),
            )
            .unwrap();
        (top, mid)
    };
    rep.bench("artists", "artist profile, most prolific", || {
        lib.artist_profile(&top_artist).unwrap()
    });
    rep.bench("artists", "artist profile, median artist", || {
        lib.artist_profile(&mid_artist).unwrap()
    });

    // --- genres --------------------------------------------------------
    rep.bench("genres", "genre list", || lib.genres().unwrap());
    let genre = lib.genres().unwrap()[0].name.clone();
    rep.bench("genres", "genre detail (top genre)", || {
        lib.genre_detail(&genre).unwrap()
    });
    rep.bench("genres", "genre tracks page 100 @0 (top genre)", || {
        lib.genre_tracks_page(&genre, 0, 100).unwrap()
    });
    rep.bench("genres", "genre tracks page 100 @1000 (top genre)", || {
        lib.genre_tracks_page(&genre, 1_000, 100).unwrap()
    });

    // --- stats ---------------------------------------------------------
    let year_start = now - 320 * 86_400; // roughly "this year"
    let periods: [(&str, Option<i64>, Option<i64>); 6] = [
        ("last 7 days", Some(now - 7 * 86_400), Some(now + 86_400)),
        ("last 30 days", Some(now - 30 * 86_400), Some(now + 86_400)),
        ("this year", Some(year_start), Some(now + 86_400)),
        (
            "last year",
            Some(year_start - 365 * 86_400),
            Some(year_start),
        ),
        (
            "custom 90 days",
            Some(now - 90 * 86_400),
            Some(now + 86_400),
        ),
        ("all time", None, None),
    ];
    for (label, from, to) in periods {
        rep.bench("stats", &format!("listening_stats, {label}"), || {
            lib.listening_stats(from, to).unwrap()
        });
    }

    // --- home ----------------------------------------------------------
    rep.bench("home", "home_feed", || lib.home_feed().unwrap());
    let feed = lib.home_feed().unwrap();
    if let Some(mix) = feed.mixes.first() {
        let id = mix.id.clone();
        rep.bench("home", &format!("home_mix_detail ({})", mix.kind), || {
            lib.home_mix_detail(&id).unwrap()
        });
    }

    // --- playlists & favourites -----------------------------------------
    rep.bench("lists", "playlists (all 200, sidebar)", || {
        lib.playlists().unwrap()
    });
    rep.bench("lists", "playlist page 100 (one playlist)", || {
        lib.playlist_tracks(sc.playlists as i64 / 2, 0, 100)
            .unwrap()
    });
    {
        let name = "favourites page 100 @0";
        rep.bench("lists", name, || lib.favorites_page(0, 100).unwrap());
        if ms(rep.rows.last().unwrap().median.unwrap()) > 50.0 {
            let c = lib.conn();
            explain(
                &c,
                name,
                &format!(
                    "{TRACK_COLS} JOIN favorites f ON f.track_id = t.id AND f.profile_id = 1 \
                     ORDER BY f.added_at DESC, t.title COLLATE NOCASE, f.track_id LIMIT 100"
                ),
            );
        }
    }
    rep.bench("lists", "favourites ids (all, for the stars)", || {
        lib.favorites().unwrap()
    });

    // --- misc / queue building -------------------------------------------
    rep.bench("misc", "library_stats (counts)", || lib.stats().unwrap());
    rep.bench("queue", "play all: all_tracks(artist)", || {
        lib.all_tracks(SortOrder::Artist).unwrap()
    });
    rep.bench("queue", "play all: all_tracks(title)", || {
        lib.all_tracks(SortOrder::Title).unwrap()
    });
    rep.bench("queue", "play search: matching_tracks(love)", || {
        lib.matching_tracks(SortOrder::Artist, "love").unwrap()
    });
    rep.bench("queue", "play album: album_tracks", || {
        lib.album_tracks(mid_album).unwrap()
    });
    rep.bench("queue", "play playlist: playlist_queue_tracks", || {
        lib.playlist_queue_tracks(sc.playlists as i64 / 2).unwrap()
    });
    rep.bench("queue", "play favourites: favorites_queue_tracks", || {
        lib.favorites_queue_tracks().unwrap()
    });
    rep.bench("queue", "play artist: artist_tracks (prolific)", || {
        lib.artist_tracks(&top_artist).unwrap()
    });
    rep.bench("queue", "play genre: genre_tracks (top genre)", || {
        lib.genre_tracks(&genre).unwrap()
    });

    // `NM_BENCH_SKIP_SYNC=1` stops before the sync steps (library queries only).
    if std::env::var_os("NM_BENCH_SKIP_SYNC").is_some() {
        rep.print_table();
        if std::env::var_os("NM_BENCH_KEEP").is_some() {
            println!("kept: {}", tmp.keep().display());
        }
        return;
    }

    // --- sync ----------------------------------------------------------
    let backups = tmp.path().join("backups");
    {
        let conn = lib.conn();
        let mut now_ms = now * 1000;
        rep.bench("sync", "Resolver::load (via resolve_key)", || {
            store::resolve_key(&conn, "x\u{1f}y\u{1f}z", None).unwrap()
        });
        let first = rep.once("sync", "capture, first (everything new)", || {
            store::capture(&conn, now_ms, &[ProfileId::FIRST]).unwrap()
        });
        println!("    first capture stamped {} rows", first.stamped);
        rep.bench("sync", "capture, idle", || {
            now_ms += 1000;
            store::capture(&conn, now_ms, &[ProfileId::FIRST]).unwrap()
        });

        // A second device (an in-memory phone) with ~1 000 changes.
        let batch = second_device_batch(&metas, now);
        println!(
            "    peer batch: {} favourites, {} playlists, {} entries, {} listens",
            batch.favorites.len(),
            batch.playlists.len(),
            batch.entries.len(),
            batch.listens.len()
        );
        store::upsert_peer(
            &conn,
            &batch.from_device,
            "phone",
            b"bench-secret",
            ProfileId::FIRST,
        )
        .unwrap();
        let opts = ApplyOptions {
            profile: ProfileId::FIRST,
            peer_id: Some(batch.from_device.clone()),
            peer_name: "phone".into(),
            allow_mass_delete: false,
            backup_dir: None,
            now_ms,
        };
        let empty = Batch {
            from_device: batch.from_device.clone(),
            upto_seq: 0,
            more: false,
            ..Batch::default()
        };
        rep.bench("sync", "apply, empty batch (idle round)", || {
            store::apply(&conn, &empty, &opts).unwrap()
        });
        rep.once(
            "sync",
            &format!("plan, {} changes (read-only)", batch.len()),
            || store::plan(&conn, ProfileId::FIRST, &batch, now_ms).unwrap(),
        );
        let report = rep.once(
            "sync",
            &format!("apply, {} changes from peer", batch.len()),
            || store::apply(&conn, &batch, &opts).unwrap(),
        );
        println!("    merged: {:?}", report.merged);
        rep.bench("sync", "apply, same batch again (all known)", || {
            store::apply(&conn, &batch, &opts).unwrap()
        });
        rep.bench("sync", "quick_check", || store::quick_check(&conn).unwrap());
        let mut backup_now = now_ms;
        rep.bench("sync", "backup_if_due (VACUUM INTO)", || {
            backup_now += store::BACKUP_INTERVAL_MS + 1000;
            store::backup_if_due(&conn, &backups, backup_now).unwrap()
        });
    }
    let backup_size = std::fs::read_dir(&backups)
        .ok()
        .and_then(|d| {
            d.filter_map(|e| e.ok())
                .map(|e| file_mb(&e.path()))
                .reduce(f64::max)
        })
        .unwrap_or(0.0);
    lib.conn()
        .execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
        .unwrap();
    let size_after_sync = file_mb(&db_path);

    // --- rescan ---------------------------------------------------------
    rescan_benchmark(&mut rep);

    // --- report ---------------------------------------------------------
    rep.print_table();
    println!(
        "\ndatabase file: {size_before_sync:.1} MB after generation, {size_after_sync:.1} MB \
         after the sync steps; one VACUUM INTO backup: {backup_size:.1} MB"
    );
    if std::env::var_os("NM_BENCH_KEEP").is_some() {
        println!("kept: {}", tmp.keep().display());
    }
}

/// A phone with ~1 000 changes whose songs exist in the big library: 400
/// favourites, 5 playlists x 100 entries and ~100 listens.
fn second_device_batch(metas: &[TrackMeta], now: i64) -> Batch {
    let mut conn = Connection::open_in_memory().unwrap();
    db::init(&conn).unwrap();
    conn.execute("INSERT INTO folders(id, path) VALUES (1, '/phone')", [])
        .unwrap();
    store::set_device_name(&conn, "phone").unwrap();
    let mut ids = Vec::new();
    {
        let tx = conn.transaction().unwrap();
        // Same artist/album/title (so the same sync key), different paths.
        for (i, m) in metas.iter().take(1_000).enumerate() {
            tx.execute(
                "INSERT OR IGNORE INTO albums(title, album_artist) VALUES (?1, ?2)",
                [&m.album, &m.artist],
            )
            .unwrap();
            let album: i64 = tx
                .query_row(
                    "SELECT id FROM albums WHERE title = ?1 AND album_artist = ?2",
                    [&m.album, &m.artist],
                    |r| r.get(0),
                )
                .unwrap();
            tx.execute(
                "INSERT INTO tracks(folder_id, path, mtime, size, title, artist, album_id,
                                    duration_ms, added_at)
                 VALUES (1, ?1, 1, 1, ?2, ?3, ?4, ?5, 1)",
                params![
                    format!("/phone/{i}.m4a"),
                    m.title,
                    m.artist,
                    album,
                    m.duration_ms
                ],
            )
            .unwrap();
            ids.push(tx.last_insert_rowid());
        }
        tx.commit().unwrap();
    }
    for id in ids.iter().take(400) {
        db::toggle_favorite(&conn, ProfileId::FIRST, *id, now).unwrap();
    }
    for p in 0..5 {
        let slice = &ids[p * 100..p * 100 + 100];
        db::create_playlist(
            &mut conn,
            ProfileId::FIRST,
            &format!("Phone list {p}"),
            slice,
            now,
        )
        .unwrap();
    }
    for (i, m) in metas.iter().take(100).enumerate() {
        db::record_listen_event(
            &conn,
            ProfileId::FIRST,
            &crate::library::NewListenEvent {
                path: format!("/phone/{i}.m4a"),
                title: m.title.clone(),
                artist: m.artist.clone(),
                duration_ms: Some(m.duration_ms as u64),
                started_at: now - 3_600 - i as i64 * 400,
                ended_at: now - 3_000 - i as i64 * 400,
                listened_ms: m.duration_ms as u64,
                completed: true,
                skipped: false,
            },
        )
        .unwrap();
    }
    store::capture(&conn, now * 1000, &[ProfileId::FIRST]).unwrap();
    store::changes_since(&conn, ProfileId::FIRST, 0, 200_000).unwrap()
}

/// Generates tiny tagged WAVs, scans them, then rescans with nothing changed.
fn rescan_benchmark(rep: &mut Report) {
    let n: usize = std::env::var("NM_BENCH_FILES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3_000);
    let tmp = tempfile::tempdir().unwrap();
    let music = tmp.path().join("music");
    let t = Instant::now();
    let per_album = 10;
    for i in 0..n {
        let dir = music.join(format!(
            "Artist {}/Album {}",
            (i / per_album) % 40,
            i / per_album
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("{:02} - Track {i}.wav", i % per_album + 1));
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 8000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut w = hound::WavWriter::create(&path, spec).unwrap();
        for s in 0..8000 {
            w.write_sample((s % 100) as i16).unwrap();
        }
        w.finalize().unwrap();
        let mut tag = Tag::new(TagType::Id3v2);
        tag.set_title(format!("Track {i} Şarkı"));
        tag.set_artist(format!("Artist {}", (i / per_album) % 40));
        tag.set_album(format!("Album {}", i / per_album));
        tag.set_track((i % per_album + 1) as u32);
        tag.save_to_path(&path, WriteOptions::default()).unwrap();
    }
    println!(
        "generated {n} audio files in {:.1} s",
        t.elapsed().as_secs_f64()
    );

    let lib = Library::open(
        &tmp.path().join("data/library.sqlite3"),
        &tmp.path().join("cache/covers"),
        Hooks::none(),
    )
    .unwrap();
    let folder = lib.add_folder(music.to_str().unwrap()).unwrap();
    let first = rep.once("rescan", &format!("first scan, {n} files"), || {
        scan_folder(&lib, folder, &music).unwrap()
    });
    println!("    first scan: {first:?}");
    let first_ms = ms(rep.rows.last().unwrap().cold);
    rep.bench(
        "rescan",
        &format!("rescan, {n} files, nothing changed"),
        || scan_folder(&lib, folder, &music).unwrap(),
    );
    let med = ms(rep.rows.last().unwrap().median.unwrap());
    println!(
        "    per file: first scan {:.3} ms, rescan {:.3} ms -> 50 000 files: first {:.1} s, rescan {:.1} s",
        first_ms / n as f64,
        med / n as f64,
        first_ms / n as f64 * 50.0,
        med / n as f64 * 50.0
    );
}
