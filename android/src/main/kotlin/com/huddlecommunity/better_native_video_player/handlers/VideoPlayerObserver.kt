package com.huddlecommunity.better_native_video_player.handlers

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.C

/**
 * Observes ExoPlayer state changes and reports them via EventHandler
 * Equivalent to iOS VideoPlayerObserver
 */
class VideoPlayerObserver(
    private val player: Player,
    private val eventHandler: VideoPlayerEventHandler,
    private val notificationHandler: com.huddlecommunity.better_native_video_player.handlers.VideoPlayerNotificationHandler? = null,
    private val getMediaInfo: (() -> Map<String, Any>?)? = null,
    private val controllerId: Int? = null,
    private val viewId: Long? = null,
    private val isInPipMode: () -> Boolean = { false }
) : Player.Listener {

    companion object {
        private const val TAG = "VideoPlayerObserver"
        private const val UPDATE_INTERVAL_MS = 1000L
        private const val STALL_WATCHDOG_MS = 12_000L
        private const val MAX_RECOVERY_ATTEMPTS = 3
    }

    // Track if we've already sent a buffering event to avoid duplicates
    private var hasReportedBuffering = false

    // Track Cast/external playback connection state
    private var wasExternalPlaybackActive = false

    // Reusable objects to avoid per-cycle allocations on the main thread
    private val handler = Handler(Looper.getMainLooper())
    private val timelineWindow = Timeline.Window()

    // Stall watchdog: detects indefinite STATE_BUFFERING and forces recovery
    private var stallWatchdogRunnable: Runnable? = null
    private var stallRecoveryAttempt = 0

    // Guard to start timeUpdateRunnable only once (on first STATE_READY)
    private var isTimeUpdateRunning = false

    private val timeUpdateRunnable = object : Runnable {
        override fun run() {
            var position: Long
            var duration: Long

            val timeline = player.currentTimeline

            // getWindow populates timelineWindow and returns it — single call
            val isLiveStream = !timeline.isEmpty &&
                timeline.getWindow(player.currentMediaItemIndex, timelineWindow).isDynamic &&
                !timelineWindow.isSeekable

            if (isLiveStream) {
                duration = timelineWindow.durationMs
                // currentPosition is already relative to the window start —
                // windowStartTimeMs is a Unix-epoch timestamp and must not
                // be subtracted from it.
                position = player.currentPosition

                if (position < 0) position = 0
                if (position > duration) position = duration
            } else {
                position = player.currentPosition
                duration = player.duration
            }

            val bufferedPosition = player.bufferedPosition.toInt()
            val isBuffering = player.playbackState == Player.STATE_BUFFERING

            if (duration > 0) {
                eventHandler.sendEvent("timeUpdate", mapOf(
                    "position" to position.toInt(),
                    "duration" to duration.toInt(),
                    "bufferedPosition" to bufferedPosition,
                    "isBuffering" to isBuffering
                ))
            }

            handler.postDelayed(this, UPDATE_INTERVAL_MS)
        }
    }

    // timeUpdateRunnable is started on the first STATE_READY transition
    // to avoid ticking every second before any media is loaded.

    fun release() {
        // Stop periodic updates
        if (isTimeUpdateRunning) {
            handler.removeCallbacks(timeUpdateRunnable)
            isTimeUpdateRunning = false
        }
        cancelStallWatchdog()
    }

    private fun startStallWatchdog() {
        cancelStallWatchdog()
        val runnable = Runnable {
            // playWhenReady=false means the user paused — recovery would
            // force-resume against their intent. onPlayWhenReadyChanged
            // re-arms the watchdog if they resume while still buffering.
            if (player.playbackState == Player.STATE_BUFFERING && player.playWhenReady) {
                stallRecoveryAttempt++

                if (stallRecoveryAttempt > MAX_RECOVERY_ATTEMPTS) {
                    Log.e(TAG, "Stall watchdog exceeded $MAX_RECOVERY_ATTEMPTS attempts — giving up")
                    eventHandler.sendEvent("error", mapOf("message" to "Playback stalled after $MAX_RECOVERY_ATTEMPTS recovery attempts"))
                    return@Runnable
                }

                hasReportedBuffering = false
                eventHandler.sendEvent("buffering")
                hasReportedBuffering = true

                if (stallRecoveryAttempt <= 1 || isInPipMode()) {
                    // Light recovery: re-prepare, preserving the media source.
                    // Always use light recovery during PiP — stop() is destructive and kills PiP.
                    // Only live streams get the default-position seek (the live
                    // edge); for VOD the default position is the window start
                    // and would yank the viewer back to 0:00.
                    Log.w(TAG, "Stall watchdog fired (attempt $stallRecoveryAttempt, pip=${isInPipMode()}) — light recovery")
                    if (player.isCurrentMediaItemLive) {
                        player.seekToDefaultPosition()
                    }
                    player.prepare()
                    player.play()
                } else {
                    // Heavy recovery: tear down and re-prepare from scratch.
                    Log.w(TAG, "Stall watchdog fired (attempt $stallRecoveryAttempt) — full stop/prepare/play")
                    player.stop()
                    player.prepare()
                    player.play()
                }

                // Re-arm for next attempt if still stuck
                startStallWatchdog()
            }
        }
        stallWatchdogRunnable = runnable
        handler.postDelayed(runnable, STALL_WATCHDOG_MS)
    }

    private fun cancelStallWatchdog() {
        stallWatchdogRunnable?.let { handler.removeCallbacks(it) }
        stallWatchdogRunnable = null
    }

    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
        if (!playWhenReady) {
            // User paused — don't let the watchdog force-resume playback.
            cancelStallWatchdog()
        } else if (player.playbackState == Player.STATE_BUFFERING) {
            // Resumed while still buffering — restore stall detection.
            startStallWatchdog()
        }
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
        Log.d(TAG, "Playback state changed: $playbackState, isLoading: ${player.isLoading}")
        when (playbackState) {
            Player.STATE_IDLE -> {
                cancelStallWatchdog()
            }
            Player.STATE_BUFFERING -> {
                // Start watchdog to detect indefinite buffering
                startStallWatchdog()
                // Send buffering event when entering BUFFERING state
                // Only send if we haven't already reported buffering
                if (!hasReportedBuffering) {
                    Log.d(TAG, "Entering BUFFERING state, sending buffering event")
                    eventHandler.sendEvent("buffering")
                    hasReportedBuffering = true
                }
            }
            Player.STATE_READY -> {
                cancelStallWatchdog()
                // Reset buffering flag and recovery counter when we're ready
                hasReportedBuffering = false
                stallRecoveryAttempt = 0

                // Start periodic time updates on first ready
                if (!isTimeUpdateRunning) {
                    handler.post(timeUpdateRunnable)
                    isTimeUpdateRunning = true
                }

                // Ready state is handled by onIsLoadingChanged when loading finishes
                // But send loaded event with duration here as it's state-specific
                val duration = player.duration.toInt()
                if (duration > 0 && !player.isLoading) {
                    eventHandler.sendEvent("loaded", mapOf("duration" to duration))
                }
            }
            Player.STATE_ENDED -> {
                cancelStallWatchdog()
                // When looping is enabled with REPEAT_MODE_ONE, this state shouldn't be reached
                // as ExoPlayer handles looping internally. However, handle it for safety.
                // Check actual repeat mode instead of stale enableLooping parameter
                if (player.repeatMode != Player.REPEAT_MODE_ONE) {
                    // Reset video to the beginning and pause
                    player.seekTo(0)
                    player.pause()
                    eventHandler.sendEvent("completed")
                }
                // Don't send completed event when looping (repeat mode is ON)
                // This ensures consistent behavior even if setLooping() was called after observer init
            }
        }
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        Log.d(TAG, "Is playing changed: $isPlaying, playbackState: ${player.playbackState}")
        if (isPlaying) {
            // ALWAYS update media session/notification when playback starts
            // This ensures media controls show the correct info whether in normal view or PiP
            val mediaInfo = getMediaInfo?.invoke()
            if (mediaInfo != null && notificationHandler != null) {
                val title = mediaInfo["title"] as? String
                Log.d(TAG, "📱 [Observer] Player started playing, updating media session for: $title")
                notificationHandler.setupMediaSession(mediaInfo)
                Log.d(TAG, "✅ [Observer] Media session updated - controls should now show correct info")
            } else {
                if (mediaInfo == null) {
                    Log.w(TAG, "⚠️ [Observer] No media info available when playing - media controls may not show correctly")
                }
                if (notificationHandler == null) {
                    Log.w(TAG, "⚠️ [Observer] No notification handler available")
                }
            }
            eventHandler.sendEvent("play")
        } else {
            // Only send pause event if not buffering
            // When seeking to unbuffered position, isPlaying becomes false but player is buffering
            // We should not report this as a pause - the buffering event will be sent instead
            if (player.playbackState != Player.STATE_BUFFERING) {
                eventHandler.sendEvent("pause")
            }
        }
    }

    override fun onIsLoadingChanged(isLoading: Boolean) {
        Log.d(TAG, "Is loading changed: $isLoading, playbackState: ${player.playbackState}, isPlaying: ${player.isPlaying}, playWhenReady: ${player.playWhenReady}")

        // Send buffering event when loading starts in BUFFERING state
        // This catches cases where isLoading changes before playbackState
        // Only send if we haven't already reported buffering
        if (isLoading && player.playbackState == Player.STATE_BUFFERING && !hasReportedBuffering) {
            Log.d(TAG, "Loading started while in BUFFERING state, sending buffering event")
            eventHandler.sendEvent("buffering")
            hasReportedBuffering = true
        } else if (!isLoading && player.playbackState == Player.STATE_READY) {
            // Reset buffering flag when loading finishes
            hasReportedBuffering = false

            // Note: "loaded" event is already sent by onPlaybackStateChanged when STATE_READY is reached
            // No need to send it again here

            // Restore the playback state after buffering completes
            // This tells the UI whether the video is playing or paused
            // IMPORTANT: Only send play/pause if player is not currently buffering
            // During initial buffering, isPlaying might be true (playWhenReady=true)
            // but the video hasn't actually started playing yet
            if (player.playbackState != Player.STATE_BUFFERING) {
                if (player.isPlaying) {
                    eventHandler.sendEvent("play")
                } else {
                    eventHandler.sendEvent("pause")
                }
            }
        }
    }

    override fun onPlayerError(error: PlaybackException) {
        if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
            // Fell behind the live window — seek to live edge and re-prepare
            Log.w(TAG, "Behind live window, seeking to live edge")
            eventHandler.sendEvent("buffering")
            // Mark reported so the STATE_BUFFERING transition from prepare()
            // doesn't emit a duplicate buffering event.
            hasReportedBuffering = true
            player.seekToDefaultPosition()
            player.prepare()
            player.play()
        } else {
            Log.e(TAG, "Player error: ${error.message}", error)
            eventHandler.sendEvent(
                "error",
                mapOf("message" to (error.message ?: "Unknown error"))
            )
        }
    }

    override fun onDeviceInfoChanged(deviceInfo: androidx.media3.common.DeviceInfo) {
        // Check if playing to a remote device (Cast)
        val isExternalPlaybackActive = deviceInfo.playbackType == androidx.media3.common.DeviceInfo.PLAYBACK_TYPE_REMOTE

        // Only send event if the state changed
        if (isExternalPlaybackActive != wasExternalPlaybackActive) {
            wasExternalPlaybackActive = isExternalPlaybackActive
            Log.d(TAG, "Cast/external playback changed: $isExternalPlaybackActive")
            eventHandler.sendEvent(
                "airPlayConnectionChanged",
                mapOf("isConnected" to isExternalPlaybackActive)
            )
        }
    }
}
