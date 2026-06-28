package com.huddlecommunity.better_native_video_player

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.huddlecommunity.better_native_video_player.manager.SharedPlayerManager

/**
 * Foreground service of type mediaPlayback. Holds the process alive so the
 * shared ExoPlayer keeps decoding audio when the app is backgrounded / screen
 * locked — Android 17 silently silences background audio without a compliant
 * foreground service.
 *
 * Reuses the existing MediaSession notification from VideoPlayerNotificationHandler
 * (via SharedPlayerManager) so there is exactly one media notification.
 *
 * Started by `setBackgroundPlaybackEnabled(true)` *while the app is visible* so
 * the FGS is granted while-in-use capability; stopped when disabled.
 */
class PlaybackForegroundService : Service() {
    companion object {
        private const val TAG = "PlaybackFgService"

        fun start(context: Context) {
            context.startForegroundService(
                Intent(context, PlaybackForegroundService::class.java),
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackForegroundService::class.java))
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val active = SharedPlayerManager.activeForegroundNotification()
        if (active == null) {
            // No active player/notification to foreground — nothing to keep alive.
            Log.w(TAG, "No active media notification; stopping service")
            stopSelf()
            return START_NOT_STICKY
        }
        val (notificationId, notification) = active
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                notificationId,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(notificationId, notification)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
