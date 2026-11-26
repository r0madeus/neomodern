//! Autoplay service (decision K18): when the last song of the queue starts
//! and nothing would follow, a background thread picks fitting songs from
//! the library (`library::autoplay`) and appends them, so playback goes on
//! without a gap. Songs played in this session or still queued are not
//! picked again; when the whole library has been played, the session's
//! played set starts over.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::library::Library;
use crate::player::{Player, PlayerSnapshot, Status};
use crate::queue::{RepeatMode, Track};

/// How many songs one top-up adds.
const BATCH: usize = 5;
/// How many of the last queued songs describe "what was playing".
const SEEDS: usize = 5;

#[derive(Default)]
pub struct Autoplay {
    busy: AtomicBool,
    played: Mutex<HashSet<String>>,
    /// Queue version for which nothing could be found (do not retry it).
    gave_up: Mutex<Option<u64>>,
}

impl Autoplay {
    /// Called with every player state; starts a top-up when needed.
    pub fn on_state(
        self: &Arc<Self>,
        snap: &PlayerSnapshot,
        enabled: bool,
        player: Arc<Player>,
        lib: Arc<Library>,
    ) {
        let Some(current) = &snap.current else {
            return;
        };
        self.played
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(current.path.clone());
        let needed = enabled
            && snap.next_track.is_none()
            && snap.repeat == RepeatMode::Off
            && snap.status != Status::Stopped;
        if !needed
            || *self.gave_up.lock().unwrap_or_else(|e| e.into_inner()) == Some(snap.queue_version)
            || self.busy.swap(true, Ordering::SeqCst)
        {
            return;
        }
        let this = Arc::clone(self);
        let version = snap.queue_version;
        std::thread::spawn(move || {
            if !this.top_up(&player, &lib) {
                *this.gave_up.lock().unwrap_or_else(|e| e.into_inner()) = Some(version);
            }
            this.busy.store(false, Ordering::SeqCst);
        });
    }

    /// Appends fitting songs; false when nothing could be found.
    fn top_up(&self, player: &Player, lib: &Library) -> bool {
        let queued: Vec<String> = player
            .queue_page(0, usize::MAX)
            .into_iter()
            .map(|t| t.path)
            .collect();
        let seeds: Vec<String> = queued.iter().rev().take(SEEDS).rev().cloned().collect();
        let mut exclude: HashSet<String> = queued.iter().cloned().collect();
        exclude.extend(
            self.played
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .iter()
                .cloned(),
        );
        let mut picks = lib
            .autoplay_picks(&seeds, &exclude, BATCH)
            .unwrap_or_else(|e| {
                log::warn!("autoplay: {e}");
                Vec::new()
            });
        if picks.is_empty() {
            // Everything was played: start over (still not what is queued).
            self.played
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clear();
            let exclude: HashSet<String> = queued.iter().cloned().collect();
            picks = lib
                .autoplay_picks(&seeds, &exclude, BATCH)
                .unwrap_or_default();
        }
        if picks.is_empty() {
            return false;
        }
        log::info!("autoplay: adding {} songs", picks.len());
        let tracks: Vec<Track> = picks
            .into_iter()
            .map(|t| Track {
                path: PathBuf::from(t.path),
                title: Some(t.title),
                artist: Some(t.artist),
            })
            .collect();
        if let Err(e) = player.append(tracks) {
            log::warn!("autoplay: {e}");
            return false;
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::Hooks;
    use crate::player::bulk_tests::Silent;
    use std::time::{Duration, Instant};

    fn setup() -> (tempfile::TempDir, Arc<Library>, Arc<Player>) {
        let tmp = tempfile::tempdir().unwrap();
        let lib = Library::open(
            &tmp.path().join("db.sqlite3"),
            &tmp.path().join("covers"),
            Hooks::none(),
        )
        .unwrap();
        let folder = lib.add_folder(tmp.path().to_str().unwrap()).unwrap();
        for (path, artist) in [("a", "X"), ("b", "X"), ("c", "Y"), ("d", "Z")] {
            lib.conn()
                .execute(
                    "INSERT INTO tracks(folder_id, path, mtime, size, title, artist, added_at)
                     VALUES (?1, ?2, 0, 0, ?2, ?3, 0)",
                    rusqlite::params![folder, path, artist],
                )
                .unwrap();
        }
        let player = Arc::new(Player::new(Box::new(Silent), Box::new(|_| {})));
        (tmp, Arc::new(lib), player)
    }

    fn wait_idle(auto: &Autoplay) {
        let start = Instant::now();
        while auto.busy.load(Ordering::SeqCst) && start.elapsed() < Duration::from_secs(5) {
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn the_last_song_gets_fitting_songs_after_it() {
        let (_tmp, lib, player) = setup();
        let auto = Arc::new(Autoplay::default());
        let snap = player.replace_queue(vec![PathBuf::from("a")], 0).unwrap();
        assert!(snap.next_track.is_none());
        auto.on_state(&snap, true, Arc::clone(&player), Arc::clone(&lib));
        wait_idle(&auto);
        let queue: Vec<String> = player
            .queue_page(0, 10)
            .into_iter()
            .map(|t| t.path)
            .collect();
        assert_eq!(queue.len(), 4, "{queue:?}");
        assert_eq!(queue[0], "a");
        assert_eq!(queue[1], "b", "the same artist comes first");
        assert!(
            player.snapshot().next_track.is_some(),
            "no gap: the next song is set"
        );
    }

    #[test]
    fn nothing_is_added_when_off_or_repeating() {
        let (_tmp, lib, player) = setup();
        let auto = Arc::new(Autoplay::default());
        let snap = player.replace_queue(vec![PathBuf::from("a")], 0).unwrap();
        auto.on_state(&snap, false, Arc::clone(&player), Arc::clone(&lib));
        wait_idle(&auto);
        assert_eq!(player.queue_page(0, 10).len(), 1);
        let snap = player.set_repeat(RepeatMode::All).unwrap();
        auto.on_state(&snap, true, Arc::clone(&player), Arc::clone(&lib));
        wait_idle(&auto);
        assert_eq!(player.queue_page(0, 10).len(), 1);
    }
}
