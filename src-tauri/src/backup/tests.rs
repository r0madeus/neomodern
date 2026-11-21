//! Backup, import, swap, move-folder and automatic-backup tests. Plain temp
//! folders and generated WAV files; no Tauri, no sound card, no network.

use super::archive::{self, Limits, Manifest, ManifestEntry, Output};
use super::auto::{self, Decision};
use super::swap::{self, BEFORE_IMPORT_PREFIX, ROLLBACK_DIR, STAGING_DIR};
use super::{FORMAT_VERSION, LIBRARY, MANIFEST, SESSION};
use crate::library::db::SCHEMA_VERSION;
use crate::library::scan::{display_path, scan_folder};
use crate::library::{Hooks, Library, NewListenEvent};
use crate::session::{self, AutoBackup, BackupInterval, SavedTrack, SessionState};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use tempfile::TempDir;

fn write_wav(path: &Path) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: 8000,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut w = hound::WavWriter::create(path, spec).unwrap();
    for i in 0..800 {
        w.write_sample((i % 100) as i16).unwrap();
    }
    w.finalize().unwrap();
}

fn open_lib(data: &Path, cache: &Path) -> Library {
    Library::open_with_first_profile_name(
        &data.join(LIBRARY),
        &cache.join("covers"),
        Hooks::none(),
        "Owner",
    )
    .unwrap()
    .with_user_images_dir(data.join("images"))
}

fn tracks(lib: &Library) -> Vec<(i64, String)> {
    let conn = lib.conn();
    let mut st = conn
        .prepare("SELECT id, path FROM tracks ORDER BY path")
        .unwrap();
    st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn count(lib: &Library, sql: &str) -> i64 {
    lib.conn().query_row(sql, [], |r| r.get(0)).unwrap()
}

fn listen(lib: &Library, path: &str, at: i64) {
    lib.record_listen_event(NewListenEvent {
        path: path.into(),
        title: "t".into(),
        artist: "a".into(),
        duration_ms: Some(1000),
        started_at: at,
        ended_at: at + 1000,
        listened_ms: 1000,
        completed: true,
        skipped: false,
    })
    .unwrap();
}

fn canonical(p: &Path) -> String {
    display_path(&std::fs::canonicalize(p).unwrap())
}

/// A data folder with music, two profiles (the second with a PIN),
/// favourites, playlists, listens, kept images, lyrics and a session.
struct Source {
    tmp: TempDir,
    data: PathBuf,
    music: PathBuf,
}

fn source() -> Source {
    let tmp = TempDir::new().unwrap();
    let data = tmp.path().join("data-a");
    let music = tmp.path().join("music");
    for name in ["a/one.wav", "a/two.wav", "b/three.wav"] {
        write_wav(&music.join(name));
    }
    let lib = open_lib(&data, &tmp.path().join("cache-a"));
    let folder = lib.add_folder(music.to_str().unwrap()).unwrap();
    scan_folder(&lib, folder, Path::new(&canonical(&music))).unwrap();
    let t = tracks(&lib);
    assert_eq!(t.len(), 3);

    let second = lib.create_profile("Deniz").unwrap();
    lib.set_profile_pin(second.id, Some("2468")).unwrap();
    lib.toggle_favorite(t[0].0).unwrap();
    lib.create_playlist("Road", &[t[0].0, t[2].0]).unwrap();
    listen(&lib, &t[0].1, 1_000_000);
    lib.set_active_profile(second.id).unwrap();
    lib.toggle_favorite(t[1].0).unwrap();
    lib.toggle_favorite(t[2].0).unwrap();
    lib.create_playlist("Night", &[t[1].0]).unwrap();
    listen(&lib, &t[1].1, 2_000_000);
    listen(&lib, &t[2].1, 3_000_000);

    // Kept images (one referenced by an album) and lyrics.
    for (dir, file) in [
        ("images/playlists", "p1.jpg"),
        ("images/albums", "al.jpg"),
        ("images/artists", "ar.jpg"),
        ("lyrics", "abc123.json"),
    ] {
        let p = super::entry_path(&data, dir).join(file);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, format!("{dir}/{file}")).unwrap();
    }
    let cover = display_path(&data.join("images/playlists/p1.jpg"));
    lib.conn()
        .execute(
            "UPDATE playlists SET cover = ?1 WHERE name = 'Road'",
            [&cover],
        )
        .unwrap();
    drop(lib);

    let mut state = SessionState {
        queue: vec![SavedTrack {
            path: PathBuf::from(&t[0].1),
            title: Some("one".into()),
            artist: None,
        }],
        current_index: Some(0),
        active_profile: 1,
        auto_backup: AutoBackup {
            enabled: true,
            folder: Some(PathBuf::from("/somewhere/on/a")),
            ..AutoBackup::default()
        },
        ..SessionState::default()
    };
    state.profiles.insert(
        second.id.0,
        session::ProfileSession {
            queue: vec![SavedTrack {
                path: PathBuf::from(&t[1].1),
                title: None,
                artist: None,
            }],
            ..Default::default()
        },
    );
    session::save(&data.join(SESSION), &state).unwrap();
    Source { tmp, data, music }
}

fn export(src: &Source) -> PathBuf {
    let out = src.tmp.path().join("out").join("NeoModern-backup.nmbackup");
    let info = archive::export(&src.data, &out, 1_794_746_096_000).unwrap();
    assert_eq!(info.size, std::fs::metadata(&out).unwrap().len());
    assert!(!archive::partial_path(&out).exists());
    out
}

fn dir_names(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    v.sort();
    v
}

#[test]
fn export_inspect_import_round_trip() {
    let src = source();
    let file = export(&src);

    // Inspect leaves nothing behind.
    let work = src.tmp.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let summary = archive::inspect(&file, &work).unwrap();
    assert!(dir_names(&work).is_empty());
    assert_eq!(
        summary.profiles,
        vec!["Owner".to_string(), "Deniz".to_string()]
    );
    assert_eq!(
        (
            summary.tracks,
            summary.playlists,
            summary.favorites,
            summary.listens,
            summary.folders
        ),
        (3, 2, 3, 3, 1)
    );
    assert_eq!(summary.schema_version, SCHEMA_VERSION);
    assert_eq!(summary.app_version, env!("CARGO_PKG_VERSION"));
    assert_eq!(summary.created_at, 1_794_746_096_000);
    assert_eq!(summary.entries, 6);

    // Another device with its own data and automatic-backup folder.
    let dest = src.tmp.path().join("data-b");
    let other_music = src.tmp.path().join("other-music");
    write_wav(&other_music.join("x.wav"));
    {
        let lib = open_lib(&dest, &src.tmp.path().join("cache-b"));
        lib.add_folder(other_music.to_str().unwrap()).unwrap();
        std::fs::create_dir_all(dest.join("lyrics")).unwrap();
        std::fs::write(dest.join("lyrics/old.json"), "old").unwrap();
    }
    let device_backup = AutoBackup {
        enabled: true,
        folder: Some(PathBuf::from("/device/b/folder")),
        interval: BackupInterval::Week,
        keep: 10,
        ..AutoBackup::default()
    };
    session::save(
        &dest.join(SESSION),
        &SessionState {
            auto_backup: device_backup.clone(),
            ..SessionState::default()
        },
    )
    .unwrap();

    let staged = swap::stage_import(&file, &dest, 1_794_746_100_000).unwrap();
    assert!(staged.restart_required);
    assert_eq!(staged.summary.tracks, 3);
    let before = PathBuf::from(&staged.before_import);
    assert!(before.join(LIBRARY).is_file());
    assert!(before.join("lyrics/old.json").is_file());
    assert!(swap::import_staged(&dest));

    // Next start-up.
    let outcome = swap::apply_pending_import(&dest).unwrap();
    assert!(outcome.applied, "{outcome:?}");
    assert!(!dest.join(STAGING_DIR).exists());
    assert!(!dest.join(ROLLBACK_DIR).exists());
    assert!(swap::apply_pending_import(&dest).is_none());

    let lib = open_lib(&dest, &src.tmp.path().join("cache-b"));
    let profiles = lib.profiles().unwrap();
    assert_eq!(profiles.len(), 2);
    assert!(!profiles[0].has_pin && profiles[1].has_pin);
    lib.check_profile_pin(profiles[1].id, Some("2468")).unwrap();
    assert_eq!(lib.folders().unwrap()[0].path, canonical(&src.music));
    assert_eq!(tracks(&lib).len(), 3);
    assert_eq!(lib.favorites().unwrap().len(), 1);
    assert_eq!(lib.playlists().unwrap()[0].name, "Road");
    lib.set_active_profile(profiles[1].id).unwrap();
    assert_eq!(lib.favorites().unwrap().len(), 2);
    assert_eq!(lib.playlists().unwrap()[0].name, "Night");
    assert_eq!(count(&lib, "SELECT COUNT(*) FROM listen_events"), 3);
    // Kept images now point into this data folder.
    lib.set_active_profile(profiles[0].id).unwrap();
    assert_eq!(
        lib.playlists().unwrap()[0].cover,
        Some(display_path(&dest.join("images/playlists/p1.jpg")))
    );
    for f in [
        "images/playlists/p1.jpg",
        "images/albums/al.jpg",
        "images/artists/ar.jpg",
        "lyrics/abc123.json",
    ] {
        assert_eq!(std::fs::read_to_string(dest.join(f)).unwrap(), f);
    }
    assert!(!dest.join("lyrics/old.json").exists());

    let state = session::load(&dest.join(SESSION));
    assert_eq!(state.queue.len(), 1);
    assert_eq!(state.profiles.len(), 1);
    // This device's automatic backup is kept.
    assert_eq!(state.auto_backup, device_backup);
}

#[test]
fn import_never_deletes_tracks_whose_files_are_missing() {
    let src = source();
    let lib = open_lib(&src.data, &src.tmp.path().join("cache-a"));
    let folder = lib.folders().unwrap()[0].clone();
    std::fs::remove_file(src.music.join("b/three.wav")).unwrap();
    lib.keep_missing_on_next_scan([folder.id]);
    let stats = scan_folder(&lib, folder.id, Path::new(&folder.path)).unwrap();
    assert_eq!(stats.removed, 0);
    assert_eq!(tracks(&lib).len(), 3);
    // Only the first scan after the import; later scans clean up as usual.
    let stats = scan_folder(&lib, folder.id, Path::new(&folder.path)).unwrap();
    assert_eq!(stats.removed, 1);

    // An unreachable root never loses tracks.
    std::fs::rename(&src.music, src.tmp.path().join("elsewhere")).unwrap();
    assert!(scan_folder(&lib, folder.id, Path::new(&folder.path)).is_err());
    assert_eq!(tracks(&lib).len(), 2);
    assert!(!lib.folder_status().unwrap()[0].reachable);
}

#[test]
fn failed_swap_rolls_back() {
    let src = source();
    let file = export(&src);
    let dest = src.tmp.path().join("data-b");
    let other_music = src.tmp.path().join("other-music");
    write_wav(&other_music.join("x.wav"));
    {
        let lib = open_lib(&dest, &src.tmp.path().join("cache-b"));
        lib.add_folder(other_music.to_str().unwrap()).unwrap();
        std::fs::create_dir_all(dest.join("images/albums")).unwrap();
        std::fs::write(dest.join("images/albums/mine.jpg"), "mine").unwrap();
    }
    std::fs::write(dest.join(SESSION), br#"{"volume":42}"#).unwrap();
    let db_before = std::fs::read(dest.join(LIBRARY)).unwrap();

    swap::stage_import(&file, &dest, 1_794_746_100_000).unwrap();
    let outcome = swap::apply_pending_import_with(&dest, &mut |slot| {
        if slot == "images/albums" {
            Err(std::io::Error::other("disk full"))
        } else {
            Ok(())
        }
    })
    .unwrap();
    assert!(!outcome.applied);
    assert!(outcome.error.unwrap().contains("disk full"));
    assert_eq!(std::fs::read(dest.join(LIBRARY)).unwrap(), db_before);
    assert_eq!(
        std::fs::read(dest.join(SESSION)).unwrap(),
        br#"{"volume":42}"#
    );
    assert_eq!(
        std::fs::read_to_string(dest.join("images/albums/mine.jpg")).unwrap(),
        "mine"
    );
    assert!(!dest.join("lyrics").exists());
    assert!(!dest.join(STAGING_DIR).exists());
    assert!(!dest.join(ROLLBACK_DIR).exists());
    let lib = open_lib(&dest, &src.tmp.path().join("cache-b"));
    assert_eq!(lib.folders().unwrap()[0].path, canonical(&other_music));
}

#[test]
fn interrupted_swap_is_undone_at_the_next_start() {
    let tmp = TempDir::new().unwrap();
    let data = tmp.path();
    // State after a crash: the old session set aside, the new one placed,
    // part of the staging still there.
    std::fs::create_dir_all(data.join(ROLLBACK_DIR)).unwrap();
    std::fs::write(data.join(ROLLBACK_DIR).join(".swapping"), "").unwrap();
    std::fs::write(data.join(ROLLBACK_DIR).join(SESSION), "old").unwrap();
    std::fs::write(data.join(SESSION), "new").unwrap();
    std::fs::create_dir_all(data.join(STAGING_DIR)).unwrap();
    std::fs::write(data.join(STAGING_DIR).join(".ready"), "{}").unwrap();

    let outcome = swap::apply_pending_import(data).unwrap();
    assert!(!outcome.applied);
    assert_eq!(std::fs::read_to_string(data.join(SESSION)).unwrap(), "old");
    assert!(!data.join(ROLLBACK_DIR).exists());
    assert!(!data.join(STAGING_DIR).exists());
    // An incomplete staging (no ready marker) is discarded, not applied.
    std::fs::create_dir_all(data.join(STAGING_DIR)).unwrap();
    std::fs::write(data.join(STAGING_DIR).join(SESSION), "half").unwrap();
    assert!(swap::apply_pending_import(data).is_none());
    assert_eq!(std::fs::read_to_string(data.join(SESSION)).unwrap(), "old");
    assert!(!data.join(STAGING_DIR).exists());
}

#[test]
fn before_import_copies_keep_the_newest_three() {
    let tmp = TempDir::new().unwrap();
    let data = tmp.path();
    std::fs::write(data.join(SESSION), "{}").unwrap();
    std::fs::create_dir_all(data.join("before-import-notes")).unwrap();
    std::fs::write(data.join("before-import-20200101T000000Z"), "a file").unwrap();
    let day = 86_400_000;
    let made: Vec<PathBuf> = (0..5)
        .map(|i| swap::copy_before_import(data, 1_794_746_096_000 + i * day).unwrap())
        .collect();
    let left: Vec<String> = dir_names(data)
        .into_iter()
        .filter(|n| n.starts_with(BEFORE_IMPORT_PREFIX))
        .collect();
    assert_eq!(
        left,
        vec![
            "before-import-20200101T000000Z".to_string(),
            "before-import-20261117T123456Z".into(),
            "before-import-20261118T123456Z".into(),
            "before-import-20261119T123456Z".into(),
            "before-import-notes".into(),
        ]
    );
    assert!(made[4].join(SESSION).is_file());
}

// --- crafted bad archives -------------------------------------------------

enum Item<'a> {
    File(&'a str, Vec<u8>),
    Link(&'a str, &'a str),
}

fn valid_db(tmp: &Path) -> Vec<u8> {
    let lib = open_lib(&tmp.join("db-src"), &tmp.join("db-cache"));
    drop(lib);
    let out = tmp.join("db-copy.sqlite3");
    let _ = std::fs::remove_file(&out);
    archive::copy_database(&tmp.join("db-src").join(LIBRARY), &out).unwrap();
    std::fs::read(out).unwrap()
}

fn sha(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn manifest_for(items: &[Item<'_>]) -> Manifest {
    Manifest {
        format: FORMAT_VERSION,
        app_version: "test".into(),
        schema_version: SCHEMA_VERSION,
        created_at: 1,
        platform: "linux".into(),
        data_dir: String::new(),
        entries: items
            .iter()
            .filter_map(|i| match i {
                Item::File(name, bytes) => Some(ManifestEntry {
                    name: (*name).into(),
                    size: bytes.len() as u64,
                    sha256: sha(bytes),
                }),
                Item::Link(..) => None,
            })
            .collect(),
    }
}

fn craft(path: &Path, items: &[Item<'_>], manifest: Option<&Manifest>) {
    use zip::write::SimpleFileOptions;
    let mut zip = zip::ZipWriter::new(std::fs::File::create(path).unwrap());
    let opts = SimpleFileOptions::default();
    for item in items {
        match item {
            Item::File(name, bytes) => {
                zip.start_file(*name, opts).unwrap();
                zip.write_all(bytes).unwrap();
            }
            Item::Link(name, target) => zip.add_symlink(*name, *target, opts).unwrap(),
        }
    }
    if let Some(m) = manifest {
        zip.start_file(MANIFEST, opts).unwrap();
        zip.write_all(&serde_json::to_vec(m).unwrap()).unwrap();
    }
    zip.finish().unwrap();
}

fn rejected(tmp: &Path, items: &[Item<'_>], edit: impl FnOnce(&mut Manifest)) -> String {
    rejected_with(tmp, items, edit, Limits::DEFAULT)
}

fn rejected_with(
    tmp: &Path,
    items: &[Item<'_>],
    edit: impl FnOnce(&mut Manifest),
    limits: Limits,
) -> String {
    let mut m = manifest_for(items);
    edit(&mut m);
    let file = tmp.join("bad.nmbackup");
    craft(&file, items, Some(&m));
    let db = tmp.join("check.sqlite3");
    let names: Vec<String> = items
        .iter()
        .map(|i| match i {
            Item::File(n, _) | Item::Link(n, _) => n.to_string(),
        })
        .collect();
    let err = archive::verify_with(&file, Output::DatabaseOnly(&db), limits)
        .err()
        .unwrap_or_else(|| panic!("archive must be refused: {names:?}"))
        .to_string();
    let _ = std::fs::remove_file(&db);
    err
}

#[test]
fn every_validation_rule_refuses_a_crafted_archive() {
    let tmp = TempDir::new().unwrap();
    let t = tmp.path();
    let db = valid_db(t);
    let lib = || Item::File(LIBRARY, db.clone());

    // The base archive is accepted.
    let ok = t.join("ok.nmbackup");
    let items = [lib(), Item::File(SESSION, b"{}".to_vec())];
    craft(&ok, &items, Some(&manifest_for(&items)));
    archive::verify(&ok, Output::DatabaseOnly(&t.join("ok.sqlite3"))).unwrap();

    let cases: Vec<(&str, String)> = vec![
        (
            "leaves",
            rejected(
                t,
                &[lib(), Item::File("../evil.txt", b"x".to_vec())],
                |_| {},
            ),
        ),
        (
            "leaves",
            rejected(
                t,
                &[
                    lib(),
                    Item::File("images/playlists/../../evil", b"x".to_vec()),
                ],
                |_| {},
            ),
        ),
        (
            "absolute",
            rejected(t, &[lib(), Item::File("/etc/evil", b"x".to_vec())], |_| {}),
        ),
        (
            "absolute",
            rejected(t, &[lib(), Item::File("C:/evil", b"x".to_vec())], |_| {}),
        ),
        (
            "links",
            rejected(
                t,
                &[lib(), Item::Link("images/playlists/a.jpg", "/etc/passwd")],
                |_| {},
            ),
        ),
        (
            "unknown entry",
            rejected(t, &[lib(), Item::File("notes.txt", b"x".to_vec())], |_| {}),
        ),
        (
            "unknown entry",
            rejected(
                t,
                &[lib(), Item::File("images/other/a.jpg", b"x".to_vec())],
                |_| {},
            ),
        ),
        (
            "unknown entry",
            rejected(
                t,
                &[lib(), Item::File("lyrics/sub/a.json", b"x".to_vec())],
                |_| {},
            ),
        ),
        (
            "checksum mismatch",
            rejected(t, &[lib()], |m| m.entries[0].sha256 = sha(b"other")),
        ),
        (
            "size mismatch",
            rejected(t, &[lib()], |m| m.entries[0].size += 1),
        ),
        (
            "not listed",
            rejected(t, &[lib(), Item::File(SESSION, b"{}".to_vec())], |m| {
                m.entries.retain(|e| e.name != SESSION)
            }),
        ),
        (
            "missing from backup",
            rejected(t, &[lib()], |m| {
                m.entries.push(ManifestEntry {
                    name: "lyrics/x.json".into(),
                    size: 1,
                    sha256: sha(b"x"),
                })
            }),
        ),
        (
            "newer version",
            rejected(t, &[lib()], |m| m.schema_version = SCHEMA_VERSION + 1),
        ),
        (
            "newer version",
            rejected(t, &[lib()], |m| m.format = FORMAT_VERSION + 1),
        ),
        (
            "image too large",
            rejected_with(
                t,
                &[lib(), Item::File("images/artists/big.jpg", vec![0; 2048])],
                |_| {},
                Limits {
                    image_bytes: 1024,
                    ..Limits::DEFAULT
                },
            ),
        ),
        (
            "larger than",
            rejected_with(
                t,
                &[lib()],
                |_| {},
                Limits {
                    total_bytes: 1024,
                    ..Limits::DEFAULT
                },
            ),
        ),
        (
            "too many files",
            rejected_with(
                t,
                &[
                    lib(),
                    Item::File("lyrics/a", vec![1]),
                    Item::File("lyrics/b", vec![2]),
                ],
                |_| {},
                Limits {
                    entries: 2,
                    ..Limits::DEFAULT
                },
            ),
        ),
        (
            "damaged",
            rejected(
                t,
                &[Item::File(LIBRARY, b"SQLite format 3\0garbage".repeat(300))],
                |_| {},
            ),
        ),
        (
            "session.json is not valid",
            rejected(t, &[lib(), Item::File(SESSION, b"[1,2".to_vec())], |_| {}),
        ),
        (
            "no library",
            rejected(t, &[Item::File(SESSION, b"{}".to_vec())], |_| {}),
        ),
    ];
    for (want, got) in cases {
        assert!(got.contains(want), "expected '{want}', got '{got}'");
    }

    // A corrupted page inside a real database.
    let mut broken = db.clone();
    let page = 4096;
    assert!(broken.len() > 2 * page);
    // Every page's b-tree header and cell pointers after the first.
    for start in (page..broken.len()).step_by(page) {
        for b in &mut broken[start..start + 64] {
            *b = 0x5a;
        }
    }
    let got = rejected(t, &[Item::File(LIBRARY, broken)], |_| {});
    assert!(
        got.contains("damaged") || got.contains("cannot be opened"),
        "{got}"
    );

    // No manifest, not a zip.
    let file = t.join("nomanifest.nmbackup");
    craft(&file, &[lib()], None);
    let err = archive::inspect(&file, t).unwrap_err().to_string();
    assert!(err.contains("no manifest"), "{err}");
    std::fs::write(&file, b"hello").unwrap();
    let err = archive::inspect(&file, t).unwrap_err().to_string();
    assert!(err.contains("not a zip"), "{err}");

    // A refused import leaves the data folder as it was.
    let data = t.join("data");
    std::fs::create_dir_all(&data).unwrap();
    std::fs::write(data.join(SESSION), "{}").unwrap();
    assert!(swap::stage_import(&file, &data, 1).is_err());
    assert_eq!(dir_names(&data), vec![SESSION.to_string()]);
}

// --- move folder ------------------------------------------------------------

#[test]
fn move_folder_keeps_favourites_playlists_and_listens() {
    let tmp = TempDir::new().unwrap();
    let old = tmp.path().join("music1");
    let sibling = tmp.path().join("music1b");
    for name in ["a/one.wav", "a/two.wav"] {
        write_wav(&old.join(name));
    }
    write_wav(&sibling.join("s.wav"));
    let lib = std::sync::Arc::new(open_lib(
        &tmp.path().join("data"),
        &tmp.path().join("cache"),
    ));
    let id = lib.add_folder(old.to_str().unwrap()).unwrap();
    let sib = lib.add_folder(sibling.to_str().unwrap()).unwrap();
    scan_folder(&lib, id, Path::new(&canonical(&old))).unwrap();
    scan_folder(&lib, sib, Path::new(&canonical(&sibling))).unwrap();
    let before = tracks(&lib);
    let (one, two, s) = (before[0].clone(), before[1].clone(), before[2].clone());
    assert!(s.1.contains("music1b"));
    lib.toggle_favorite(one.0).unwrap();
    let pl = lib.create_playlist("P", &[one.0, two.0]).unwrap();
    listen(&lib, &one.1, 10);
    listen(&lib, &s.1, 20);

    // The drive moved: the old root is gone.
    let new = tmp.path().join("music2");
    std::fs::rename(&old, &new).unwrap();
    let status = lib.folder_status().unwrap();
    assert!(!status.iter().find(|f| f.id == id).unwrap().reachable);
    assert!(status.iter().find(|f| f.id == sib).unwrap().reachable);

    let check = lib
        .folder_check_move(id, tmp.path().join("nowhere").to_str().unwrap())
        .unwrap();
    assert_eq!((check.exists, check.found, check.total), (false, 0, 2));
    let check = lib.folder_check_move(id, new.to_str().unwrap()).unwrap();
    assert_eq!(
        (check.exists, check.found, check.checked, check.total),
        (true, 2, 2, 2)
    );
    // Another library folder cannot be the target.
    assert!(lib.move_folder(id, sibling.to_str().unwrap()).is_err());

    let moved = lib.move_folder(id, new.to_str().unwrap()).unwrap();
    assert_eq!(moved.path, canonical(&new));
    let after = tracks(&lib);
    let new_one = after.iter().find(|t| t.0 == one.0).unwrap();
    assert_eq!(
        new_one.1,
        display_path(&new.join("a/one.wav").canonicalize().unwrap())
    );
    // The sibling whose name starts the same is untouched.
    assert_eq!(after.iter().find(|t| t.0 == s.0).unwrap().1, s.1);
    assert_eq!(lib.favorites().unwrap()[0].track_id, one.0);
    assert_eq!(lib.favorites().unwrap()[0].path, new_one.1);
    assert_eq!(lib.playlist_tracks(pl.id, 0, 10).unwrap().len(), 2);
    let paths: Vec<String> = {
        let conn = lib.conn();
        let mut st = conn
            .prepare("SELECT path FROM listen_events ORDER BY started_at")
            .unwrap();
        st.query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(paths, vec![new_one.1.clone(), s.1.clone()]);

    // The rescan finds the same files: nothing added or removed.
    let stats = scan_folder(&lib, id, &new.canonicalize().unwrap()).unwrap();
    assert_eq!((stats.updated, stats.removed), (0, 0));
    assert_eq!(tracks(&lib).len(), 3);
    assert!(lib.folder_status().unwrap().iter().all(|f| f.reachable));
}

#[test]
fn move_folder_into_its_own_subfolder() {
    let tmp = TempDir::new().unwrap();
    let root = tmp.path().join("m");
    // `m/sub/x.wav` becomes `m/sub/sub/x.wav` while `m/x.wav` becomes
    // `m/sub/x.wav`: a new path equals another track's old one.
    write_wav(&root.join("x.wav"));
    write_wav(&root.join("sub/x.wav"));
    let lib = open_lib(&tmp.path().join("data"), &tmp.path().join("cache"));
    let id = lib.add_folder(root.to_str().unwrap()).unwrap();
    scan_folder(&lib, id, &root.canonicalize().unwrap()).unwrap();
    let before = tracks(&lib);
    std::fs::create_dir_all(root.join("sub/sub")).unwrap();
    lib.move_folder(id, root.join("sub").to_str().unwrap())
        .unwrap();
    let after = tracks(&lib);
    assert_eq!(after.len(), 2);
    let sub = canonical(&root.join("sub"));
    for (id, path) in &before {
        let new = &after.iter().find(|t| t.0 == *id).unwrap().1;
        let rel = path.strip_prefix(&canonical(&root)).unwrap();
        assert_eq!(*new, format!("{sub}{rel}"));
    }
}

// --- automatic backup -------------------------------------------------------

#[test]
fn automatic_backup_due_logic_uses_the_given_clock() {
    let day = 24 * 60 * 60 * 1000;
    let now = 1_794_746_096_000;
    let mut a = AutoBackup::default();
    assert_eq!(a.keep, 5);
    assert_eq!(
        auto::decide(&a, now, false, false),
        Decision::Wait(auto::CHECK_EVERY)
    );
    a.enabled = true;
    assert!(!auto::is_due(&a, now), "no folder");
    a.folder = Some(PathBuf::from("/backups"));
    assert_eq!(auto::decide(&a, now, false, false), Decision::Run);
    assert_eq!(
        auto::decide(&a, now, true, false),
        Decision::Wait(auto::BUSY_RETRY)
    );
    assert_eq!(
        auto::decide(&a, now, false, true),
        Decision::Wait(auto::BUSY_RETRY)
    );
    a.last_at = Some(now - day + 1);
    assert!(!auto::is_due(&a, now));
    a.last_at = Some(now - day);
    assert!(auto::is_due(&a, now));
    a.interval = BackupInterval::Week;
    assert!(!auto::is_due(&a, now));
    assert!(auto::is_due(&a, now - day + 7 * day));
    // The clock went back.
    a.last_at = Some(now + day);
    assert!(auto::is_due(&a, now));
    a.enabled = false;
    assert!(!auto::is_due(&a, now));
}

#[test]
fn automatic_backup_writes_named_files_and_rotation_touches_nothing_else() {
    let src = source();
    let folder = src.tmp.path().join("cloud");
    std::fs::create_dir_all(folder.join("NeoModern-backup-2020-01-01-0000.nmbackup")).unwrap();
    let others = [
        "notes.txt",
        "my.nmbackup",
        "NeoModern-backup-2020-01-01-0000.nmbackup.partial",
        "NeoModern-backup-2020-01-01.nmbackup",
    ];
    for o in others {
        std::fs::write(folder.join(o), "keep me").unwrap();
    }
    let hour = 60 * 60 * 1000;
    let start = 1_794_746_096_000;
    for i in 0..7 {
        let info = auto::run(&src.data, &folder, 5, start + i * hour).unwrap();
        assert!(info.size > 0);
    }
    // Same minute twice: a second name, not an overwrite.
    auto::run(&src.data, &folder, 5, start + 6 * hour).unwrap();
    let names = dir_names(&folder);
    let ours: Vec<&String> = names
        .iter()
        .filter(|n| n.ends_with(".nmbackup") && n.starts_with("NeoModern-backup-2026"))
        .collect();
    assert_eq!(
        ours,
        vec![
            "NeoModern-backup-2026-11-15-1534.nmbackup",
            "NeoModern-backup-2026-11-15-1634.nmbackup",
            "NeoModern-backup-2026-11-15-1734.nmbackup",
            "NeoModern-backup-2026-11-15-1834-2.nmbackup",
            "NeoModern-backup-2026-11-15-1834.nmbackup",
        ]
    );
    for o in others {
        assert_eq!(std::fs::read_to_string(folder.join(o)).unwrap(), "keep me");
    }
    assert!(
        folder
            .join("NeoModern-backup-2020-01-01-0000.nmbackup")
            .is_dir()
    );
    assert!(
        !names
            .iter()
            .any(|n| n.ends_with(".partial") && n.contains("2026"))
    );
    // Each one is a valid backup.
    archive::inspect(&folder.join(ours[4]), &src.tmp.path().join("w")).unwrap();
    assert!(auto::run(&src.data, &src.tmp.path().join("missing"), 5, start).is_err());
}

#[test]
fn auto_backup_settings_default_off_and_are_clamped() {
    let s: SessionState = serde_json::from_str("{}").unwrap();
    assert!(!s.auto_backup.enabled);
    assert_eq!(s.auto_backup.keep, 5);
    let s: SessionState =
        serde_json::from_str(r#"{"autoBackup":{"enabled":true,"keep":7,"interval":"week"}}"#)
            .unwrap();
    let s = s.normalized();
    assert_eq!(s.auto_backup.keep, 5);
    assert_eq!(s.auto_backup.interval, BackupInterval::Week);
    assert!(s.auto_backup.enabled);
}

#[test]
fn entry_names_are_classified_strictly() {
    use super::{EntryKind, classify};
    assert_eq!(classify(LIBRARY), Ok(EntryKind::Library));
    assert_eq!(classify("images/albums/a b.jpg"), Ok(EntryKind::Image));
    assert_eq!(classify("lyrics/k.json"), Ok(EntryKind::Lyrics));
    for bad in [
        "images/albums/",
        "images/albums",
        "images/albums/a:b.jpg",
        "images/albums/a\\b.jpg",
        "images/albums/con.",
        "Library.sqlite3",
        "lyrics/./a",
        "",
    ] {
        assert!(classify(bad).is_err(), "{bad}");
    }
}
