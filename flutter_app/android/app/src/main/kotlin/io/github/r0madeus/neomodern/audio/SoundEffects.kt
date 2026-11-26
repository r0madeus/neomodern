package io.github.r0madeus.neomodern.audio

import android.content.Context
import android.media.audiofx.Equalizer
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import kotlin.math.ln

/**
 * Equalizer and crossfade tail for the shared ExoPlayer (decision K16).
 * Main thread only, like the player.
 *
 * The equalizer settings are NeoModern's ten octave bands (same as mpv on
 * desktop); the system equalizer has its own bands (often five), so each
 * of its bands gets our curve at its center frequency.
 */
class SoundEffects(private val context: Context, private val handler: Handler) {
    private var equalizer: Equalizer? = null
    private var equalizerSession = C.AUDIO_SESSION_ID_UNSET
    private var enabled = false
    private var preampDb = 0.0
    private var gainsDb = DoubleArray(10)

    fun setEqualizer(sessionId: Int, enabled: Boolean, preampDb: Double, gainsDb: DoubleArray) {
        this.enabled = enabled
        this.preampDb = preampDb
        this.gainsDb = if (gainsDb.size == 10) gainsDb else DoubleArray(10)
        apply(sessionId)
    }

    /** (Re)applies the settings; also called when the audio session changes. */
    fun apply(sessionId: Int) {
        if (sessionId == C.AUDIO_SESSION_ID_UNSET) return
        try {
            if (!enabled) {
                equalizer?.enabled = false
                return
            }
            if (equalizer == null || equalizerSession != sessionId) {
                equalizer?.release()
                equalizer = Equalizer(0, sessionId)
                equalizerSession = sessionId
            }
            val eq = equalizer ?: return
            val range = eq.bandLevelRange
            for (band in 0 until eq.numberOfBands) {
                val hz = eq.getCenterFreq(band.toShort()) / 1000.0
                val millibels = ((curve(hz) + preampDb) * 100).toInt()
                    .coerceIn(range[0].toInt(), range[1].toInt())
                eq.setBandLevel(band.toShort(), millibels.toShort())
            }
            eq.enabled = true
        } catch (e: Exception) {
            Log.w(TAG, "equalizer unavailable: ${e.message}")
            equalizer = null
        }
    }

    /** Our ten-band curve at `hz`, interpolated on a log-frequency scale. */
    private fun curve(hz: Double): Double {
        if (hz <= BANDS[0]) return gainsDb[0]
        for (i in 0 until BANDS.size - 1) {
            if (hz < BANDS[i + 1]) {
                val k = ln(hz / BANDS[i]) / ln(BANDS[i + 1] / BANDS[i])
                return gainsDb[i] + (gainsDb[i + 1] - gainsDb[i]) * k
            }
        }
        return gainsDb[BANDS.size - 1]
    }

    private var tail: ExoPlayer? = null
    private var tailToken = 0

    /**
     * Plays the rest of `item` from `positionMs` on a second player and
     * fades it out over `seconds`, while the main player moves on.
     */
    fun startTail(item: MediaItem, positionMs: Long, volume: Float, seconds: Double) {
        stopTail()
        val player = ExoPlayer.Builder(context.applicationContext).build()
        tail = player
        player.setMediaItem(item)
        player.seekTo(positionMs)
        player.volume = volume
        player.prepare()
        player.play()
        val token = ++tailToken
        ramp(seconds, { token == tailToken }, { k -> player.volume = volume * (1f - k) }) {
            stopTail()
        }
    }

    fun stopTail() {
        tailToken++
        tail?.release()
        tail = null
    }

    /**
     * Calls `step` with 0..1 over `seconds` (every 40 ms) while `alive`,
     * then `done`.
     */
    fun ramp(seconds: Double, alive: () -> Boolean, step: (Float) -> Unit, done: () -> Unit) {
        val start = SystemClock.uptimeMillis()
        val total = (seconds * 1000).toLong().coerceAtLeast(100)
        handler.post(object : Runnable {
            override fun run() {
                if (!alive()) return
                val k = ((SystemClock.uptimeMillis() - start).toFloat() / total).coerceIn(0f, 1f)
                step(k)
                if (k >= 1f) done() else handler.postDelayed(this, 40)
            }
        })
    }

    companion object {
        private const val TAG = "NeoModernFx"
        private val BANDS = doubleArrayOf(31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0)
    }
}
