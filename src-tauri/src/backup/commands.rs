//! Tauri commands for backup, import, automatic backup and moving a music
//! folder. File work runs on the blocking pool; results are small status
//! objects (docs/BACKUP.md, "Commands").

use super::archive::{self, BackupSummary, ExportInfo};
use super::auto::{self, Decision};
use super::swap::{self, StagedImport};
use super::{BackupError, BackupState, ImportOutcome, backup_file_name, now_ms};
use crate::library::Library;
use crate::library::relocate::{FolderStatus, MoveCheck};
use crate::player::Player;
use crate::session::{AutoBackup, BackupInterval, SessionStore};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::Arc;
use tauri::{AppHandle, Emitter, Manager, State};

type Res<T> = std::result::Result<T, String>;

pub const STATUS_EVENT: &str = "backup://status";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupStatus {
    /// Automatic backup exists on this platform (desktop).
    pub auto_available: bool,
    pub auto: AutoBackup,
    /// A backup job (export, import, automatic) is running.
    pub running: bool,
    pub import_pending: bool,
    /// The import swap done at this start-up, if any.
    pub last_import: Option<ImportOutcome>,
    /// File name to offer in the save dialog.
    pub suggested_name: String,
}

fn status(state: &BackupState, store: &SessionStore) -> BackupStatus {
    BackupStatus {
        auto_available: cfg!(not(target_os = "android")),
        auto: store.auto_backup(),
        running: state.busy(),
        import_pending: state.import_pending(),
        last_import: state.last_import(),
        suggested_name: backup_file_name(now_ms()),
    }
}

fn emit_status(app: &AppHandle) {
    if let (Some(state), Some(store)) = (
        app.try_state::<Arc<BackupState>>(),
        app.try_state::<Arc<SessionStore>>(),
    ) && let Err(e) = app.emit(STATUS_EVENT, status(&state, &store))
    {
        log::warn!("failed to emit backup status: {e}");
    }
}

/// Returns a function that saves the current queues and settings, so a
/// backup has them; run it on the blocking pool.
fn session_saver(app: &AppHandle) -> impl FnOnce() + Send + 'static {
    let store = app.try_state::<Arc<SessionStore>>().map(|s| Arc::clone(&s));
    let player = app.try_state::<Arc<Player>>().map(|p| Arc::clone(&p));
    move || {
        if let (Some(store), Some(player)) = (store, player) {
            store.save_now(&player.export_session());
        }
    }
}

async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> super::Result<T> + Send + 'static,
) -> std::result::Result<T, BackupError> {
    tauri::async_runtime::spawn_blocking(f)
        .await
        .map_err(|e| BackupError::Invalid(e.to_string()))?
}

#[tauri::command(async)]
pub fn backup_status(
    state: State<'_, Arc<BackupState>>,
    store: State<'_, Arc<SessionStore>>,
) -> BackupStatus {
    status(&state, &store)
}

/// Writes a backup to `path`; without one, into the Downloads folder (on
/// Android the system "create document" picker cannot take a binary file
/// with the current plugin, see docs/BACKUP.md).
#[tauri::command]
pub async fn backup_export(app: AppHandle, path: Option<String>) -> Res<ExportInfo> {
    let state = Arc::clone(&*app.state::<Arc<BackupState>>());
    let now = now_ms();
    let target = match path.filter(|p| !p.trim().is_empty()) {
        Some(p) => PathBuf::from(p),
        None => app
            .path()
            .download_dir()
            .map_err(|e| e.to_string())?
            .join("NeoModern")
            .join(backup_file_name(now)),
    };
    let save = session_saver(&app);
    let info = blocking(move || {
        let _job = state.begin()?;
        save();
        archive::export(&state.data_dir, &target, now)
    })
    .await;
    emit_status(&app);
    info.map_err(|e| e.to_string())
}

/// Validates a backup and says what it holds; changes nothing.
#[tauri::command]
pub async fn backup_inspect(
    state: State<'_, Arc<BackupState>>,
    path: String,
) -> Res<BackupSummary> {
    let state = Arc::clone(&state);
    blocking(move || archive::inspect(std::path::Path::new(&path), &state.data_dir))
        .await
        .map_err(|e| e.to_string())
}

/// Validates again, copies the current data aside and stages the backup.
/// The app must restart (`app_restart`) to finish.
#[tauri::command]
pub async fn backup_import(app: AppHandle, path: String) -> Res<StagedImport> {
    let state = Arc::clone(&*app.state::<Arc<BackupState>>());
    let save = session_saver(&app);
    let staged = blocking(move || {
        let job = state.begin()?;
        save();
        let staged = swap::stage_import(std::path::Path::new(&path), &state.data_dir, now_ms())?;
        state.set_import_pending();
        drop(job);
        Ok(staged)
    })
    .await;
    emit_status(&app);
    staged.map_err(|e| e.to_string())
}

/// Restarts the app (after an import). On Android the app closes and the
/// user opens it again.
#[tauri::command]
pub fn app_restart(app: AppHandle) {
    #[cfg(target_os = "android")]
    app.exit(0);
    #[cfg(not(target_os = "android"))]
    app.request_restart();
}

/// Changes the automatic backup settings (desktop only).
#[tauri::command(async)]
pub fn backup_set_auto(
    app: AppHandle,
    enabled: bool,
    folder: Option<String>,
    interval: BackupInterval,
    keep: u32,
) -> Res<BackupStatus> {
    if cfg!(target_os = "android") {
        return Err("automatic backup is not available on Android".into());
    }
    let folder = folder.filter(|f| !f.trim().is_empty()).map(PathBuf::from);
    if enabled && !folder.as_ref().is_some_and(|f| f.is_dir()) {
        return Err("choose an existing folder for the backups".into());
    }
    if !crate::session::BACKUP_KEEP_CHOICES.contains(&keep) {
        return Err(format!(
            "keep must be one of {:?}",
            crate::session::BACKUP_KEEP_CHOICES
        ));
    }
    let store = app.state::<Arc<SessionStore>>();
    store.update_auto_backup(|a| {
        if a.folder != folder {
            a.last_error = None;
        }
        a.enabled = enabled;
        a.folder = folder;
        a.interval = interval;
        a.keep = keep;
    });
    session_saver(&app)();
    let state = app.state::<Arc<BackupState>>();
    state.wake.notify_one();
    emit_status(&app);
    Ok(status(&state, &store))
}

/// Runs the automatic backup now, due or not.
#[tauri::command]
pub async fn backup_run_now(app: AppHandle) -> Res<BackupStatus> {
    run_auto(&app).await?;
    let state = app.state::<Arc<BackupState>>();
    let store = app.state::<Arc<SessionStore>>();
    Ok(status(&state, &store))
}

/// One automatic backup into the chosen folder; records the outcome in the
/// settings and tells the UI.
async fn run_auto(app: &AppHandle) -> Res<ExportInfo> {
    if cfg!(target_os = "android") {
        return Err("automatic backup is not available on Android".into());
    }
    let state = Arc::clone(&*app.state::<Arc<BackupState>>());
    let store = Arc::clone(&*app.state::<Arc<SessionStore>>());
    if app
        .try_state::<Arc<Library>>()
        .is_some_and(|l| l.is_scanning())
    {
        return Err("the library is being scanned; try again when it is done".into());
    }
    let settings = store.auto_backup();
    let Some(folder) = settings.folder.clone() else {
        return Err("choose a folder for the backups first".into());
    };
    let started = now_ms();
    let save = session_saver(app);
    let job = blocking(move || {
        let _job = state.begin()?;
        save();
        auto::run(&state.data_dir, &folder, settings.keep, started)
    })
    .await;
    // A busy refusal is not a failed backup.
    if let Err(e @ BackupError::Busy(_)) = job {
        return Err(e.to_string());
    }
    let job = job.map_err(|e| e.to_string());
    store.update_auto_backup(|a| match &job {
        Ok(info) => {
            a.last_at = Some(started);
            a.last_size = Some(info.size);
            a.last_error = None;
        }
        Err(e) => a.last_error = Some(e.clone()),
    });
    match &job {
        Ok(info) => log::info!(
            "automatic backup written: {} ({} bytes)",
            info.path,
            info.size
        ),
        Err(e) => log::warn!("automatic backup failed: {e}"),
    }
    let save = session_saver(app);
    let _ = tauri::async_runtime::spawn_blocking(save).await;
    emit_status(app);
    job
}

/// The automatic backup task: checks at start-up, then every hour (sooner
/// after a skip because a scan was running), and when settings change.
pub fn spawn_auto_backup(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        loop {
            let wait = {
                let store = app.state::<Arc<SessionStore>>();
                let state = app.state::<Arc<BackupState>>();
                let scanning = app
                    .try_state::<Arc<Library>>()
                    .is_some_and(|l| l.is_scanning());
                let busy = state.busy() || state.import_pending();
                match auto::decide(&store.auto_backup(), now_ms(), scanning, busy) {
                    Decision::Wait(d) => d,
                    Decision::Run => {
                        let _ = run_auto(&app).await;
                        auto::CHECK_EVERY
                    }
                }
            };
            let state = Arc::clone(&*app.state::<Arc<BackupState>>());
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                _ = state.wake.notified() => {}
            }
        }
    });
}

/// Library folders with whether each root is reachable now (Settings shows
/// "Music folders not found" for the others).
#[tauri::command]
pub async fn library_folders_status(lib: State<'_, Arc<Library>>) -> Res<Vec<FolderStatus>> {
    let lib = Arc::clone(&lib);
    tauri::async_runtime::spawn_blocking(move || lib.folder_status().map_err(|e| e.to_string()))
        .await
        .map_err(|e| e.to_string())?
}

/// How many of the folder's songs are found under `new_path`.
#[tauri::command]
pub async fn library_folder_check_move(
    lib: State<'_, Arc<Library>>,
    folder_id: i64,
    new_path: String,
) -> Res<MoveCheck> {
    let lib = Arc::clone(&lib);
    tauri::async_runtime::spawn_blocking(move || {
        lib.folder_check_move(folder_id, &new_path)
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Points the folder at `new_path` and rescans it.
#[tauri::command]
pub async fn library_folder_move(
    lib: State<'_, Arc<Library>>,
    folder_id: i64,
    new_path: String,
) -> Res<Vec<FolderStatus>> {
    let lib = Arc::clone(&lib);
    tauri::async_runtime::spawn_blocking(move || {
        let folder = lib
            .move_folder(folder_id, &new_path)
            .map_err(|e| e.to_string())?;
        lib.start_scan(vec![folder]);
        lib.folder_status().map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}
