//! Validation of an incoming batch, before anything is applied. One bad
//! record rejects the whole batch.

use super::hlc::{Hlc, is_id};
use super::key::is_normalized_key;
use super::local::is_valid_preset;
use super::pos;
use super::{
    Batch, EntryRecord, FavoriteRecord, ListenRecord, MAX_NAME_CHARS, MAX_PLAYLISTS, MAX_RECORDS,
    MAX_STR_BYTES, PlaylistRecord, Result, SyncError,
};
use std::collections::HashSet;

pub fn check_batch(batch: &Batch) -> Result<()> {
    if !is_id(&batch.from_device) {
        return Err(invalid("sender device id"));
    }
    if batch.upto_seq < 0 {
        return Err(invalid("negative sequence number"));
    }
    if batch.len() > MAX_RECORDS {
        return Err(invalid("too many records"));
    }
    if batch.playlists.len() > MAX_PLAYLISTS {
        return Err(invalid("too many playlists"));
    }
    unique(batch.favorites.iter().map(|f| f.key.as_str()), "favourite")?;
    unique(batch.playlists.iter().map(|p| p.uuid.as_str()), "playlist")?;
    unique(
        batch.entries.iter().map(|e| e.uuid.as_str()),
        "playlist entry",
    )?;
    unique(batch.listens.iter().map(|l| l.uid.as_str()), "listen")?;
    batch.favorites.iter().try_for_each(favorite)?;
    batch.playlists.iter().try_for_each(playlist)?;
    batch.entries.iter().try_for_each(entry)?;
    batch.listens.iter().try_for_each(listen)?;
    Ok(())
}

fn invalid(what: &str) -> SyncError {
    SyncError::Invalid(what.to_owned())
}

/// A record id appearing twice would make the outcome depend on order.
fn unique<'a>(ids: impl Iterator<Item = &'a str>, what: &str) -> Result<()> {
    let mut seen = HashSet::new();
    for id in ids {
        if !seen.insert(id) {
            return Err(SyncError::Invalid(format!("duplicate {what}")));
        }
    }
    Ok(())
}

fn text(s: &str, what: &str) -> Result<()> {
    if s.len() > MAX_STR_BYTES {
        return Err(SyncError::Invalid(format!("{what} too long")));
    }
    Ok(())
}

fn id(s: &str, what: &str) -> Result<()> {
    if is_id(s) {
        Ok(())
    } else {
        Err(SyncError::Invalid(format!("malformed {what}")))
    }
}

fn hlc(s: &str) -> Result<()> {
    if Hlc::parse(s).is_some() {
        Ok(())
    } else {
        Err(invalid("malformed clock stamp"))
    }
}

fn key(k: &str) -> Result<()> {
    text(k, "track key")?;
    if is_normalized_key(k) {
        Ok(())
    } else {
        Err(invalid("malformed track key"))
    }
}

fn duration(d: Option<i64>) -> Result<()> {
    if d.is_some_and(|d| d < 0) {
        return Err(invalid("negative duration"));
    }
    Ok(())
}

fn display(title: &str, artist: &str, album: &str) -> Result<()> {
    text(title, "title")?;
    text(artist, "artist")?;
    text(album, "album")
}

fn favorite(f: &FavoriteRecord) -> Result<()> {
    key(&f.key)?;
    display(&f.title, &f.artist, &f.album)?;
    duration(f.duration_ms)?;
    hlc(&f.hlc)
}

fn playlist(p: &PlaylistRecord) -> Result<()> {
    id(&p.uuid, "playlist id")?;
    text(&p.name, "playlist name")?;
    if p.name.trim().is_empty() || p.name.chars().count() > MAX_NAME_CHARS {
        return Err(invalid("playlist name"));
    }
    if let Some(preset) = &p.cover_preset
        && !is_valid_preset(preset)
    {
        return Err(invalid("cover preset"));
    }
    hlc(&p.name_hlc)?;
    hlc(&p.cover_hlc)?;
    hlc(&p.deleted_hlc)
}

fn entry(e: &EntryRecord) -> Result<()> {
    id(&e.uuid, "entry id")?;
    id(&e.playlist_uuid, "playlist id")?;
    key(&e.key)?;
    display(&e.title, &e.artist, &e.album)?;
    duration(e.duration_ms)?;
    if !pos::is_valid(&e.pos) {
        return Err(invalid("playlist position"));
    }
    hlc(&e.pos_hlc)?;
    hlc(&e.deleted_hlc)
}

fn listen(l: &ListenRecord) -> Result<()> {
    id(&l.uid, "listen id")?;
    key(&l.key)?;
    display(&l.title, &l.artist, &l.album)?;
    text(&l.genre, "genre")?;
    text(&l.path, "path")?;
    duration(l.duration_ms)?;
    if l.listened_ms < 0 {
        return Err(invalid("negative listening time"));
    }
    Ok(())
}
