package io.github.r0madeus.neomodern.audio

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Flutter platform bridge for Android Media3/ExoPlayer playback.
 *
 * ExoPlayer holds at most two items: the current track and the next one.
 * The queue stays in Rust (`neomodern-core`), and items are identified by
 * their path or stream URL (`MediaItem.mediaId`).
 */
class AudioBridge(private val context: Context) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private val appContext = context.applicationContext
    private val player by lazy { PlayerHolder.get(appContext) }
    private val handler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var controller: ListenableFuture<MediaController>? = null

    /** Path of the item that is playing (or loaded), as last reported to Rust. */
    private var currentPath: String? = null
    private var durationSentFor: String? = null

    /** Volume chosen by the user (already cubic), before ReplayGain. */
    private var userVolume = 1f
    /** ReplayGain factor per file path. */
    private val gains = HashMap<String, Float>()

    /** Equalizer and crossfade tail. */
    private val fx by lazy { SoundEffects(appContext, handler) }
    /** Crossfade fade-in factor for the main player (1 = full volume). */
    private var fadeFactor = 1f
    private var fadeToken = 0
    /** Fade-in length for the next `loadTrack`, armed by `beginCrossfade`. */
    private var pendingFadeIn: Double? = null

    private val positionTick = object : Runnable {
        override fun run() {
            if (player.isPlaying) {
                emitPosition(force = false)
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
            durationSentFor = null
            applyVolume()
            emit(mapOf("type" to "started", "path" to path, "auto" to true))
            // Keep [current, next]: drop the finished item in front.
            handler.post {
                while (player.currentMediaItemIndex > 0) player.removeMediaItem(0)
            }
        }

        override fun onPlaybackStateChanged(state: Int) {
            when (state) {
                Player.STATE_READY -> emitDurationIfKnown()
                Player.STATE_ENDED -> {
                    currentPath?.let { emitEnded(it, "eof") }
                    currentPath = null
                    emit(mapOf("type" to "idle"))
                }
                else -> {}
            }
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            emit(mapOf("type" to "paused", "paused" to !playWhenReady))
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            handler.removeCallbacks(positionTick)
            if (isPlaying) {
                handler.post(positionTick)
            } else {
                emitPosition(force = false)
            }
        }

        override fun onAudioSessionIdChanged(audioSessionId: Int) {
            fx.apply(audioSessionId)
        }

        override fun onPlayerError(error: PlaybackException) {
            val failed = currentPath
            emit(mapOf("type" to "error", "message" to "${error.errorCodeName}: ${error.message}"))
            failed?.let { emitEnded(it, "error") }
            currentPath = null
            if (player.hasNextMediaItem()) {
                player.seekToNextMediaItem()
                player.prepare()
            } else {
                emit(mapOf("type" to "idle"))
            }
        }
    }

    fun attach() {
        player.removeListener(listener)
        player.addListener(listener)
        PlayerHolder.onRemoteCommand = { action ->
            emit(mapOf("type" to "media", "action" to action))
        }
        if (controller == null) {
            // Binding a controller creates PlaybackService; Media3 promotes it to
            // a foreground service with a media notification during playback.
            val token = SessionToken(appContext, ComponentName(appContext, PlaybackService::class.java))
            controller = MediaController.Builder(appContext, token).buildAsync()
        }
    }

    fun detach() {
        handler.removeCallbacks(positionTick)
        player.removeListener(listener)
        if (PlayerHolder.onRemoteCommand != null) {
            PlayerHolder.onRemoteCommand = null
        }
        eventSink = null
        controller?.let { MediaController.releaseFuture(it) }
        controller = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        attach()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadTrack" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "path is required", null)
                    return
                }
                val gain = call.argument<Number>("gain")?.toDouble()
                currentPath?.let { emitEnded(it, "stopped") }
                currentPath = path
                gains.clear()
                gain?.let { gains[path] = it.toFloat() }
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
                // `load` keeps a paused engine paused; Rust calls `play`.
                player.setMediaItem(item(path))
                player.prepare()
                emit(mapOf("type" to "started", "path" to path, "auto" to false))
                result.success(null)
            }

            "setNextTrack" -> {
                val path = call.argument<String>("path")
                val gain = call.argument<Number>("gain")?.toDouble()
                if (path != null) gain?.let { gains[path] = it.toFloat() }
                val keep = player.currentMediaItemIndex + 1
                if (player.mediaItemCount > keep) {
                    player.removeMediaItems(keep, player.mediaItemCount)
                }
                if (path != null && player.mediaItemCount > 0) {
                    player.addMediaItem(item(path))
                }
                result.success(null)
            }

            "play" -> {
                if (player.playbackState == Player.STATE_IDLE && player.mediaItemCount > 0) {
                    player.prepare()
                }
                player.play()
                result.success(null)
            }

            "pause" -> {
                fx.stopTail()
                player.pause()
                result.success(null)
            }

            "stop" -> {
                fx.stopTail()
                val was = currentPath
                currentPath = null
                player.stop()
                player.clearMediaItems()
                if (was != null) {
                    emitEnded(was, "stopped")
                    emit(mapOf("type" to "idle"))
                }
                result.success(null)
            }

            "seek" -> {
                val seconds = call.argument<Number>("seconds")?.toDouble() ?: 0.0
                player.seekTo((seconds * 1000.0).toLong().coerceAtLeast(0L))
                emitPosition(force = true)
                result.success(null)
            }

            "setVolume" -> {
                val percent = (call.argument<Number>("percent")?.toDouble() ?: 100.0).coerceIn(0.0, 100.0)
                // mpv maps its 0..100 volume cubically; match it so saved volume
                // feels consistent across desktop and Android.
                val linear = percent / 100.0
                userVolume = (linear * linear * linear).toFloat()
                applyVolume()
                result.success(null)
            }

            "setGain" -> {
                val path = call.argument<String>("path")
                val gain = call.argument<Number>("gain")?.toDouble()
                if (path != null && gain != null) {
                    gains[path] = gain.toFloat()
                    if (path == currentPath) applyVolume()
                }
                result.success(null)
            }

            "setGapless" -> {
                result.success(null)
            }

            "setEqualizer" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                val preampDb = call.argument<Number>("preampDb")?.toDouble() ?: 0.0
                val gainsDb = parseGainsDb(call.argument<Any>("gainsDb"))
                fx.setEqualizer(player.audioSessionId, enabled, preampDb, gainsDb)
                result.success(null)
            }

            "beginCrossfade" -> {
                val seconds = call.argument<Number>("seconds")?.toDouble() ?: 0.0
                val path = currentPath
                if (path == null || seconds <= 0.0) {
                    result.success(false)
                    return
                }
                fx.startTail(item(path), player.currentPosition, player.volume, seconds)
                pendingFadeIn = seconds
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun parseGainsDb(raw: Any?): DoubleArray {
        val out = DoubleArray(10)
        when (raw) {
            is DoubleArray -> raw.copyInto(out, endIndex = minOf(raw.size, 10))
            is List<*> -> {
                for (i in 0 until minOf(raw.size, 10)) {
                    out[i] = (raw[i] as? Number)?.toDouble() ?: 0.0
                }
            }
        }
        return out
    }

    private fun applyVolume() {
        val gain = currentPath?.let { gains[it] } ?: 1f
        player.volume = (userVolume * gain * fadeFactor).coerceIn(0f, 1f)
    }

    private fun item(path: String): MediaItem {
        val uri = if (path.startsWith("http://", ignoreCase = true) ||
            path.startsWith("https://", ignoreCase = true) ||
            path.startsWith("content://", ignoreCase = true)
        ) {
            Uri.parse(path)
        } else {
            Uri.fromFile(File(path))
        }
        return MediaItem.Builder().setMediaId(path).setUri(uri).build()
    }

    private fun emitDurationIfKnown() {
        val path = currentPath ?: return
        val duration = player.duration
        if (duration == C.TIME_UNSET || durationSentFor == path) return
        durationSentFor = path
        emit(
            mapOf(
                "type" to "position",
                "seconds" to player.currentPosition / 1000.0,
                "duration" to duration / 1000.0,
            ),
        )
    }

    private fun emitPosition(force: Boolean) {
        val path = currentPath ?: return
        val duration = player.duration
        val durationSeconds = if (duration != C.TIME_UNSET && durationSentFor != path) {
            durationSentFor = path
            duration / 1000.0
        } else {
            null
        }
        if (!force && !player.isPlaying && durationSeconds == null) return
        val payload = HashMap<String, Any?>(3)
        payload["type"] = "position"
        payload["seconds"] = player.currentPosition / 1000.0
        if (durationSeconds != null) {
            payload["duration"] = durationSeconds
        }
        emit(payload)
    }

    private fun emitEnded(path: String, reason: String) {
        emit(mapOf("type" to "ended", "path" to path, "reason" to reason))
    }

    private fun emit(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(event)
        } else {
            handler.post { eventSink?.success(event) }
        }
    }

    companion object {
        const val METHOD_CHANNEL = "io.github.r0madeus.neomodern/audio"
        const val EVENT_CHANNEL = "io.github.r0madeus.neomodern/audio_events"
        /** At most ~4 position updates per second. */
        private const val POSITION_INTERVAL_MS = 250L
    }
}
