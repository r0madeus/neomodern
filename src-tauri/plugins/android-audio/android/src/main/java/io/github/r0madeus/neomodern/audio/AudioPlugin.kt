package io.github.r0madeus.neomodern.audio

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.activity.result.ActivityResult
import android.os.Handler
import android.os.Looper
import android.webkit.WebView
import androidx.core.content.FileProvider
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import app.tauri.PermissionState
import app.tauri.annotation.ActivityCallback
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.Permission
import app.tauri.annotation.PermissionCallback
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Channel
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import com.google.common.util.concurrent.ListenableFuture
import java.io.File

@InvokeArg
class AttachArgs {
    lateinit var events: Channel
}

@InvokeArg
class PathArgs {
    var path: String? = null
    /** ReplayGain volume factor for this file (0..1), computed in Rust. */
    var gain: Double? = null
}

@InvokeArg
class SaveTextArgs {
    lateinit var name: String
    lateinit var text: String
    var mimeType: String = "audio/x-mpegurl"
}

@InvokeArg
class InstallArgs {
    var path: String? = null
}

@InvokeArg
class SeekArgs {
    var seconds: Double = 0.0
}

@InvokeArg
class VolumeArgs {
    var percent: Double = 100.0
}

@InvokeArg
class EqualizerArgs {
    var enabled: Boolean = false
    var preampDb: Double = 0.0
    var gainsDb: DoubleArray = DoubleArray(10)
}

@InvokeArg
class CrossfadeArgs {
    var seconds: Double = 0.0
}

/**
 * Android implementation of NeoModern's `AudioEngine` (see
 * `src-tauri/src/audio/android.rs`). Commands come from Rust only.
 *
 * Like the mpv engine, ExoPlayer holds at most two items: the current track
 * and the next one. The queue stays in Rust (AGENTS.md rule 2). Items are
 * identified by their file path (`MediaItem.mediaId`).
 *
 * Events go back to Rust through the channel passed to [attach], as JSON
 * objects with a `type` field.
 */
@TauriPlugin(
    permissions = [
        Permission(strings = [Manifest.permission.READ_MEDIA_AUDIO], alias = "audio"),
        Permission(strings = [Manifest.permission.READ_EXTERNAL_STORAGE], alias = "storage"),
    ]
)
class AudioPlugin(private val activity: Activity) : Plugin(activity) {
    private val player by lazy { PlayerHolder.get(activity) }
    private val handler = Handler(Looper.getMainLooper())
    private var events: Channel? = null
    private var controller: ListenableFuture<MediaController>? = null
    private var webView: WebView? = null

    /** Path of the item that is playing (or loaded), as last reported to Rust. */
    private var currentPath: String? = null
    private var durationSentFor: String? = null

    /** Volume chosen by the user (already cubic), before ReplayGain. */
    private var userVolume = 1f
    /** ReplayGain factor per file path. */
    private val gains = HashMap<String, Float>()
    private var pendingSaveText: String? = null

    /** Equalizer and crossfade tail. */
    private val fx by lazy { SoundEffects(activity, handler) }
    /** Crossfade fade-in factor for the main player (1 = full volume). */
    private var fadeFactor = 1f
    private var fadeToken = 0
    /** Fade-in length for the next `loadTrack`, armed by `beginCrossfade`. */
    private var pendingFadeIn: Double? = null

    private val positionTick = object : Runnable {
        override fun run() {
            if (player.isPlaying) {
                emitPosition()
                handler.postDelayed(this, POSITION_INTERVAL_MS)
            }
        }
    }

    private val listener = object : Player.Listener {
        override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
            val path = item?.mediaId ?: return
            if (reason != Player.MEDIA_ITEM_TRANSITION_REASON_AUTO &&
                reason != Player.MEDIA_ITEM_TRANSITION_REASON_SEEK
            ) {
                return // `loadTrack` reports its own start
            }
            currentPath?.let { emitEnded(it, "eof") }
            currentPath = path
            applyVolume()
            emit(JSObject().put("type", "started").put("path", path).put("auto", true))
            // Keep [current, next]: drop the finished item in front.
            handler.post {
                while (player.currentMediaItemIndex > 0) player.removeMediaItem(0)
            }
        }

        override fun onPlaybackStateChanged(state: Int) {
            when (state) {
                Player.STATE_READY -> maybeEmitDuration()
                Player.STATE_ENDED -> {
                    currentPath?.let { emitEnded(it, "eof") }
                    currentPath = null
                    emit(JSObject().put("type", "idle"))
                }
                else -> {}
            }
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            emit(JSObject().put("type", "paused").put("paused", !playWhenReady))
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            handler.removeCallbacks(positionTick)
            if (isPlaying) handler.post(positionTick) else emitPosition()
        }

        override fun onAudioSessionIdChanged(audioSessionId: Int) {
            fx.apply(audioSessionId)
        }

        override fun onPlayerError(error: PlaybackException) {
            val failed = currentPath
            emit(JSObject().put("type", "error").put("message", "${error.errorCodeName}: ${error.message}"))
            failed?.let { emitEnded(it, "error") }
            currentPath = null
            // Same as mpv: skip to the next entry if there is one.
            if (player.hasNextMediaItem()) {
                player.seekToNextMediaItem()
                player.prepare()
            } else {
                emit(JSObject().put("type", "idle"))
            }
        }
    }

    override fun load(webView: WebView) {
        this.webView = webView
    }

    /**
     * How far the status bar (top) and navigation bar (bottom) overlap the
     * web view, in CSS pixels. Zero when the app is not drawn edge-to-edge.
     */
    @Command
    fun windowInsets(invoke: Invoke) {
        val view = webView
        val root = activity.window.decorView
        val insets = ViewCompat.getRootWindowInsets(root)
        if (view == null || insets == null) {
            invoke.resolve(JSObject().put("top", 0.0).put("bottom", 0.0))
            return
        }
        val bars = insets.getInsets(
            WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
        )
        val location = IntArray(2)
        view.getLocationInWindow(location)
        val top = (bars.top - location[1]).coerceAtLeast(0)
        val bottom = (location[1] + view.height - (root.height - bars.bottom)).coerceAtLeast(0)
        val density = view.resources.displayMetrics.density
        invoke.resolve(JSObject().put("top", top / density.toDouble()).put("bottom", bottom / density.toDouble()))
    }

    /** First call from Rust: wires up events and starts the media session service. */
    @Command
    fun attach(invoke: Invoke) {
        val args = invoke.parseArgs(AttachArgs::class.java)
        events = args.events
        player.removeListener(listener)
        player.addListener(listener)
        PlayerHolder.onRemoteCommand = { action ->
            emit(JSObject().put("type", "remote").put("action", action))
        }
        if (controller == null) {
            // Binding a controller creates the service; Media3 then moves it to
            // the foreground (with a notification) whenever playback runs.
            val token = SessionToken(activity, ComponentName(activity, PlaybackService::class.java))
            controller = MediaController.Builder(activity, token).buildAsync()
        }
        invoke.resolve()
    }

    @Command
    fun loadTrack(invoke: Invoke) {
        val args = invoke.parseArgs(PathArgs::class.java)
        val path = args.path
        if (path == null) {
            invoke.reject("path is required")
            return
        }
        currentPath?.let { emitEnded(it, "stopped") }
        currentPath = path
        gains.clear()
        args.gain?.let { gains[path] = it.toFloat() }
        applyVolume()
        durationSentFor = null
        fadeToken++
        val fadeIn = pendingFadeIn
        pendingFadeIn = null
        fadeFactor = if (fadeIn != null) 0f else 1f
        applyVolume()
        if (fadeIn != null) {
            val token = fadeToken
            fx.ramp(fadeIn, { token == fadeToken }, { k ->
                fadeFactor = k
                applyVolume()
            }) {}
        }
        // `load` keeps a paused engine paused (same as mpv); Rust calls `play`.
        player.setMediaItem(item(path))
        player.prepare()
        emit(JSObject().put("type", "started").put("path", path).put("auto", false))
        invoke.resolve()
    }

    @Command
    fun setNextTrack(invoke: Invoke) {
        val args = invoke.parseArgs(PathArgs::class.java)
        val path = args.path
        if (path != null) args.gain?.let { gains[path] = it.toFloat() }
        val keep = player.currentMediaItemIndex + 1
        if (player.mediaItemCount > keep) player.removeMediaItems(keep, player.mediaItemCount)
        if (path != null && player.mediaItemCount > 0) player.addMediaItem(item(path))
        invoke.resolve()
    }

    @Command
    fun play(invoke: Invoke) {
        if (player.playbackState == Player.STATE_IDLE && player.mediaItemCount > 0) player.prepare()
        player.play()
        invoke.resolve()
    }

    @Command
    fun pause(invoke: Invoke) {
        fx.stopTail()
        player.pause()
        invoke.resolve()
    }

    @Command
    fun stop(invoke: Invoke) {
        fx.stopTail()
        val was = currentPath
        currentPath = null
        player.stop()
        player.clearMediaItems()
        if (was != null) {
            emitEnded(was, "stopped")
            emit(JSObject().put("type", "idle"))
        }
        invoke.resolve()
    }

    @Command
    fun seek(invoke: Invoke) {
        val seconds = invoke.parseArgs(SeekArgs::class.java).seconds
        player.seekTo((seconds * 1000).toLong().coerceAtLeast(0))
        emitPosition()
        invoke.resolve()
    }

    @Command
    fun setVolume(invoke: Invoke) {
        val percent = invoke.parseArgs(VolumeArgs::class.java).percent.coerceIn(0.0, 100.0)
        // mpv maps its 0..100 volume cubically; do the same so a saved volume
        // sounds alike on both platforms.
        val linear = percent / 100.0
        userVolume = (linear * linear * linear).toFloat()
        applyVolume()
        invoke.resolve()
    }

    /** New ReplayGain factor for a file (the mode changed). */
    @Command
    fun setGain(invoke: Invoke) {
        val args = invoke.parseArgs(PathArgs::class.java)
        val path = args.path
        if (path != null && args.gain != null) {
            gains[path] = args.gain!!.toFloat()
            if (path == currentPath) applyVolume()
        }
        invoke.resolve()
    }

    private fun applyVolume() {
        val gain = currentPath?.let { gains[it] } ?: 1f
        player.volume = (userVolume * gain * fadeFactor).coerceIn(0f, 1f)
    }

    /** Ten-band equalizer settings from Rust (see SoundEffects). */
    @Command
    fun setEqualizer(invoke: Invoke) {
        val args = invoke.parseArgs(EqualizerArgs::class.java)
        fx.setEqualizer(player.audioSessionId, args.enabled, args.preampDb, args.gainsDb)
        invoke.resolve()
    }

    /**
     * Crossfade: the rest of the current track keeps playing on its own and
     * fades out; the next `loadTrack` fades in. Resolves `{ started }`.
     */
    @Command
    fun beginCrossfade(invoke: Invoke) {
        val seconds = invoke.parseArgs(CrossfadeArgs::class.java).seconds
        val path = currentPath
        if (path == null || seconds <= 0.0) {
            invoke.resolve(JSObject().put("started", false))
            return
        }
        fx.startTail(item(path), player.currentPosition, player.volume, seconds)
        pendingFadeIn = seconds
        invoke.resolve(JSObject().put("started", true))
    }

    /**
     * Lets the user pick a folder (system picker) and resolves `{ path }`
     * with its file-system path, or `{ path: null }` when cancelled. Only
     * folders on device storage or an SD card have such a path.
     */
    @Command
    fun pickFolder(invoke: Invoke) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        startActivityForResult(invoke, intent, "folderPicked")
    }

    @ActivityCallback
    fun folderPicked(invoke: Invoke, result: ActivityResult) {
        val uri = result.data?.data
        if (result.resultCode != Activity.RESULT_OK || uri == null) {
            invoke.resolve(JSObject().put("path", null as String?))
            return
        }
        val path = storagePath(uri, DocumentsContract.getTreeDocumentId(uri))
        if (path == null) {
            invoke.reject("Choose a folder on the device storage or SD card.")
        } else {
            invoke.resolve(JSObject().put("path", path))
        }
    }

    /** Picks one file and resolves `{ path }` (file-system path) or `{ path: null }`. */
    @Command
    fun pickFile(invoke: Invoke) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        startActivityForResult(invoke, intent, "filePicked")
    }

    @ActivityCallback
    fun filePicked(invoke: Invoke, result: ActivityResult) {
        val uri = result.data?.data
        if (result.resultCode != Activity.RESULT_OK || uri == null) {
            invoke.resolve(JSObject().put("path", null as String?))
            return
        }
        val path = filePath(uri) ?: copyUriToCache(uri)
        if (path == null) {
            invoke.reject("Open the file from the device storage (\"Browse\" in the picker).")
        } else {
            invoke.resolve(JSObject().put("path", path))
        }
    }

    /**
     * Picks one or more audio files to play. Resolves `{ paths, skipped }`:
     * file-system paths (ExoPlayer and the library work with paths), and
     * how many picked files had none (e.g. from a cloud drive).
     */
    @Command
    fun pickAudioFiles(invoke: Invoke) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "audio/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        startActivityForResult(invoke, intent, "audioFilesPicked")
    }

    @ActivityCallback
    fun audioFilesPicked(invoke: Invoke, result: ActivityResult) {
        val data = result.data
        val uris = mutableListOf<Uri>()
        if (result.resultCode == Activity.RESULT_OK && data != null) {
            val clip = data.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
            } else {
                data.data?.let { uris.add(it) }
            }
        }
        val paths = JSArray()
        var skipped = 0
        for (uri in uris) {
            val path = filePath(uri)
            if (path != null && File(path).isFile) paths.put(path) else skipped++
        }
        invoke.resolve(JSObject().put("paths", paths).put("skipped", skipped))
    }

    /** File-system path of a picked document, from storage or the media store. */
    @Suppress("DEPRECATION")
    private fun filePath(uri: Uri): String? {
        if (!DocumentsContract.isDocumentUri(activity, uri)) return null
        val docId = DocumentsContract.getDocumentId(uri)
        storagePath(uri, docId)?.let { return it }
        // "Audio", "Images", and "Recent" in the picker hand out media ids ("audio:123").
        if (uri.authority == "com.android.providers.media.documents") {
            val parts = docId.split(":", limit = 2)
            if (parts.size == 2) {
                val (contentUri, dataCol, idCol) = when (parts[0]) {
                    "audio" -> Triple(
                        MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                        MediaStore.Audio.Media.DATA,
                        MediaStore.Audio.Media._ID,
                    )
                    "image" -> Triple(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        MediaStore.Images.Media.DATA,
                        MediaStore.Images.Media._ID,
                    )
                    "video" -> Triple(
                        MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                        MediaStore.Video.Media.DATA,
                        MediaStore.Video.Media._ID,
                    )
                    else -> return null
                }
                activity.contentResolver.query(
                    contentUri,
                    arrayOf(dataCol),
                    "$idCol = ?",
                    arrayOf(parts[1]),
                    null,
                )?.use { c -> if (c.moveToFirst()) return c.getString(0) }
            }
        }
        return null
    }

    /** Copies a picked content URI into app cache (capped at 15 MB) when no direct file path exists. */
    private fun copyUriToCache(uri: Uri): String? {
        val maxBytes = 15L * 1024L * 1024L
        val dest = File(activity.cacheDir, "picked_file_cache")
        return try {
            val ok = activity.contentResolver.openInputStream(uri)?.use { input ->
                var total = 0L
                val buf = ByteArray(8192)
                dest.outputStream().use { output ->
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > maxBytes) return@use false
                        output.write(buf, 0, n)
                    }
                    true
                }
            } ?: false
            if (ok) {
                dest.absolutePath
            } else {
                dest.delete()
                null
            }
        } catch (_: Exception) {
            dest.delete()
            null
        }
    }

    /** Picks a text file (any location) and resolves `{ name, text }` or `{ text: null }`. */
    @Command
    fun openTextFile(invoke: Invoke) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        startActivityForResult(invoke, intent, "textFileOpened")
    }

    @ActivityCallback
    fun textFileOpened(invoke: Invoke, result: ActivityResult) {
        val uri = result.data?.data
        if (result.resultCode != Activity.RESULT_OK || uri == null) {
            invoke.resolve(JSObject().put("text", null as String?))
            return
        }
        try {
            val maxBytes = 2 * 1024 * 1024
            val text = activity.contentResolver.openInputStream(uri)?.use { stream ->
                val out = java.io.ByteArrayOutputStream()
                val buf = ByteArray(8192)
                var total = 0
                while (true) {
                    val remaining = (maxBytes + 1) - total
                    if (remaining <= 0) break
                    val n = stream.read(buf, 0, minOf(buf.size, remaining))
                    if (n < 0) break
                    total += n
                    if (total > maxBytes) {
                        invoke.reject("File is too large (max 2 MB)")
                        return
                    }
                    out.write(buf, 0, n)
                }
                out.toByteArray().toString(Charsets.UTF_8)
            }
            invoke.resolve(JSObject().put("name", displayName(uri)).put("text", text))
        } catch (e: Exception) {
            invoke.reject("Could not read the file: ${e.message}")
        }
    }

    /** Asks where to save `text` (system picker) and writes it; resolves `{ saved }`. */
    @Command
    fun saveTextFile(invoke: Invoke) {
        val args = invoke.parseArgs(SaveTextArgs::class.java)
        pendingSaveText = args.text
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = args.mimeType
            putExtra(Intent.EXTRA_TITLE, args.name)
        }
        startActivityForResult(invoke, intent, "textFileSaved")
    }

    @ActivityCallback
    fun textFileSaved(invoke: Invoke, result: ActivityResult) {
        val uri = result.data?.data
        val text = pendingSaveText
        pendingSaveText = null
        if (result.resultCode != Activity.RESULT_OK || uri == null || text == null) {
            invoke.resolve(JSObject().put("saved", false))
            return
        }
        try {
            activity.contentResolver.openOutputStream(uri, "wt")?.use { it.write(text.toByteArray(Charsets.UTF_8)) }
            invoke.resolve(JSObject().put("saved", true))
        } catch (e: Exception) {
            invoke.reject("Could not save the file: ${e.message}")
        }
    }

    /** `{ granted }`: whether the app may read and write all files (tag editing, .lrc). */
    @Command
    fun fileAccessStatus(invoke: Invoke) {
        invoke.resolve(JSObject().put("granted", hasFullFileAccess()))
    }

    /** Opens the system screen where the user allows access to all files. */
    @Command
    fun requestFileAccess(invoke: Invoke) {
        if (Build.VERSION.SDK_INT >= 30 && !hasFullFileAccess()) {
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:${activity.packageName}"),
            )
            try {
                activity.startActivity(intent)
            } catch (e: Exception) {
                activity.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        }
        invoke.resolve()
    }

    private fun hasFullFileAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager() else true

    /** "primary:Music/x" style document ids of the external storage provider → a path. */
    private fun storagePath(uri: Uri, docId: String): String? {
        if (uri.authority != "com.android.externalstorage.documents") return null
        val parts = docId.split(":", limit = 2)
        if (parts.size != 2) return null
        val base = if (parts[0].equals("primary", ignoreCase = true)) {
            Environment.getExternalStorageDirectory().path
        } else {
            "/storage/${parts[0]}"
        }
        return if (parts[1].isEmpty()) base else "$base/${parts[1]}"
    }

    private fun displayName(uri: Uri): String? =
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }

    private var pendingApk: String? = null

    /**
     * Opens the system installer for a downloaded update APK (a file in the
     * app's cache/updates). Asks once for "install unknown apps" first.
     * Resolves `{ started }`; false when that permission was not given.
     */
    @Command
    fun installApk(invoke: Invoke) {
        val path = invoke.parseArgs(InstallArgs::class.java).path
        if (path == null) {
            invoke.reject("No update file")
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            pendingApk = path
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + activity.packageName),
            )
            startActivityForResult(invoke, intent, "installPermissionResult")
            return
        }
        launchInstaller(invoke, path)
    }

    @ActivityCallback
    fun installPermissionResult(invoke: Invoke, result: ActivityResult) {
        val path = pendingApk
        pendingApk = null
        if (path == null) {
            invoke.reject("No update file")
            return
        }
        // The settings screen gives no result code; ask the system instead.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            invoke.resolve(JSObject().put("started", false))
            return
        }
        launchInstaller(invoke, path)
    }

    private fun launchInstaller(invoke: Invoke, path: String) {
        try {
            val uri = FileProvider.getUriForFile(
                activity,
                activity.packageName + ".neomodern.updates",
                File(path),
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            invoke.resolve(JSObject().put("started", true))
        } catch (e: Exception) {
            invoke.reject("Could not open the installer: ${e.message}")
        }
    }

    /** Asks for read access to the music library; resolves `{ granted }`. */
    @Command
    fun requestAudioAccess(invoke: Invoke) {
        val alias = accessAlias()
        if (getPermissionState(alias) == PermissionState.GRANTED) {
            invoke.resolve(JSObject().put("granted", true))
        } else {
            requestPermissionForAlias(alias, invoke, "audioAccessResult")
        }
    }

    @PermissionCallback
    fun audioAccessResult(invoke: Invoke) {
        invoke.resolve(JSObject().put("granted", getPermissionState(accessAlias()) == PermissionState.GRANTED))
    }

    private fun accessAlias() = if (Build.VERSION.SDK_INT >= 33) "audio" else "storage"

    private fun item(path: String): MediaItem {
        val uri = if (path.startsWith("http://", ignoreCase = true) || path.startsWith("https://", ignoreCase = true)) {
            Uri.parse(path)
        } else {
            Uri.fromFile(File(path))
        }
        return MediaItem.Builder().setMediaId(path).setUri(uri).build()
    }

    private fun maybeEmitDuration() {
        val path = currentPath ?: return
        val duration = player.duration
        if (duration == C.TIME_UNSET || durationSentFor == path) return
        durationSentFor = path
        emit(JSObject().put("type", "duration").put("seconds", duration / 1000.0))
    }

    private fun emitPosition() {
        if (currentPath == null) return
        maybeEmitDuration()
        emit(JSObject().put("type", "position").put("seconds", player.currentPosition / 1000.0))
    }

    private fun emitEnded(path: String, reason: String) {
        emit(JSObject().put("type", "ended").put("path", path).put("reason", reason))
    }

    private fun emit(event: JSObject) {
        events?.send(event)
    }

    private companion object {
        /** At most ~4 position updates per second (AGENTS.md rule 5). */
        const val POSITION_INTERVAL_MS = 250L
    }
}
