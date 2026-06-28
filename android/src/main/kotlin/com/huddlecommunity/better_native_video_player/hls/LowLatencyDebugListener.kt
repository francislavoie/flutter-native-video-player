package com.huddlecommunity.better_native_video_player.hls

import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import java.io.IOException

/**
 * Verbose, temporary instrumentation for diagnosing live latency / stalls.
 *
 * Logs under tag `LLDEBUG` (use `adb logcat -s LLDEBUG`). Logs playback-state
 * transitions, every media-segment / playlist load (with duration + size to
 * spot slow or failing fetches), load errors, bandwidth estimates, and the
 * live offset + buffer snapshot at each event. Remove once latency tuning is
 * settled.
 */
@UnstableApi
class LowLatencyDebugListener(private val player: ExoPlayer) : AnalyticsListener {

    private fun snapshot(): String {
        val offset = player.currentLiveOffset.let { if (it == C.TIME_UNSET) "?" else "${it}ms" }
        val ahead = player.bufferedPosition - player.currentPosition
        return "liveOffset=$offset bufAhead=${ahead}ms totalBuf=${player.totalBufferedDurationMs}ms"
    }

    override fun onPlaybackStateChanged(eventTime: AnalyticsListener.EventTime, state: Int) {
        val name = when (state) {
            Player.STATE_IDLE -> "IDLE"
            Player.STATE_BUFFERING -> "BUFFERING"
            Player.STATE_READY -> "READY"
            Player.STATE_ENDED -> "ENDED"
            else -> "?$state"
        }
        Log.i(TAG, "state=$name ${snapshot()}")
    }

    override fun onIsPlayingChanged(eventTime: AnalyticsListener.EventTime, isPlaying: Boolean) {
        Log.i(TAG, "isPlaying=$isPlaying ${snapshot()}")
    }

    override fun onPlayerError(eventTime: AnalyticsListener.EventTime, error: PlaybackException) {
        Log.w(TAG, "playerError=${error.errorCodeName}: ${error.message}")
    }

    override fun onLoadCompleted(
        eventTime: AnalyticsListener.EventTime,
        loadEventInfo: LoadEventInfo,
        mediaLoadData: MediaLoadData,
    ) {
        // Only the bits that matter for keeping up with live: how long the
        // fetch took vs how much media it delivered.
        if (mediaLoadData.dataType == C.DATA_TYPE_MEDIA ||
            mediaLoadData.dataType == C.DATA_TYPE_MANIFEST
        ) {
            val kind = if (mediaLoadData.dataType == C.DATA_TYPE_MANIFEST) "PLAYLIST" else "SEGMENT"
            Log.i(
                TAG,
                "load $kind ${loadEventInfo.loadDurationMs}ms ${loadEventInfo.bytesLoaded}B " +
                    "uri=…${tail(loadEventInfo.uri.toString())} ${snapshot()}",
            )
        }
    }

    override fun onLoadError(
        eventTime: AnalyticsListener.EventTime,
        loadEventInfo: LoadEventInfo,
        mediaLoadData: MediaLoadData,
        error: IOException,
        wasCanceled: Boolean,
    ) {
        Log.w(
            TAG,
            "LOAD_ERROR canceled=$wasCanceled type=${mediaLoadData.dataType} " +
                "err=${error.javaClass.simpleName}:${error.message} uri=…${tail(loadEventInfo.uri.toString())}",
        )
    }

    override fun onBandwidthEstimate(
        eventTime: AnalyticsListener.EventTime,
        totalLoadTimeMs: Int,
        totalBytesLoaded: Long,
        bitrateEstimate: Long,
    ) {
        Log.i(TAG, "bandwidth=${bitrateEstimate / 1000}kbps over ${totalLoadTimeMs}ms")
    }

    private fun tail(s: String): String = s.takeLast(24)

    companion object {
        private const val TAG = "LLDEBUG"
    }
}
