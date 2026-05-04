package com.huddlecommunity.better_native_video_player.handlers

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.roundToInt

/**
 * Handles HLS quality parsing and management
 */
object VideoPlayerQualityHandler {
    private const val TAG = "VideoPlayerQuality"

    data class QualityLevel(
        val url: String,
        val label: String,
        val bitrate: Int,
        val width: Int,
        val height: Int
    )

    /**
     * Fetches and parses HLS qualities from an M3U8 playlist URL
     * @param url The M3U8 playlist URL
     * @return List of quality maps with metadata
     */
    suspend fun fetchHLSQualities(url: String): List<Map<String, Any>> = withContext(Dispatchers.IO) {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = 10_000
        }
        try {
            val playlist = connection.inputStream.bufferedReader().use { it.readText() }
            parseHLSQualities(playlist, url)
        } catch (e: Exception) {
            Log.e(TAG, "Error fetching HLS qualities: ${e.message}", e)
            emptyList()
        } finally {
            connection.disconnect()
        }
    }

    internal fun parseHLSQualities(playlist: String, url: String): List<Map<String, Any>> {
        val qualities = mutableListOf<QualityLevel>()
        val lines = playlist.lines()
        var lastBitrate: Int? = null
        var lastResolution: Pair<Int, Int>? = null
        var lastFrameRate: Double? = null

        for (line in lines) {
            val trimmedLine = line.trim()
            when {
                trimmedLine.contains("#EXT-X-STREAM-INF") -> {
                    // Extract resolution
                    val resolutionMatch = Regex("RESOLUTION=(\\d+)x(\\d+)").find(trimmedLine)
                    if (resolutionMatch != null) {
                        val width = resolutionMatch.groupValues[1].toInt()
                        val height = resolutionMatch.groupValues[2].toInt()
                        lastResolution = width to height
                    }

                    // Extract bitrate
                    val bitrateMatch = Regex("BANDWIDTH=(\\d+)").find(trimmedLine)
                    lastBitrate = bitrateMatch?.groupValues?.get(1)?.toInt()

                    // Extract frame rate
                    val frameRateMatch = Regex("FRAME-RATE=(\\d+\\.?\\d*)").find(trimmedLine)
                    lastFrameRate = frameRateMatch?.groupValues?.get(1)?.toDouble()
                }
                hasPendingVariant(lastBitrate, lastResolution, lastFrameRate) &&
                    trimmedLine.isNotEmpty() &&
                    !trimmedLine.startsWith("#") -> {
                    val qualityUrl = URL(URL(url), trimmedLine).toString()

                    val resolution = lastResolution
                    if (resolution != null) {
                        val height = resolution.second
                        val label = if (lastFrameRate != null) {
                            "${height}p${lastFrameRate!!.roundToInt()}"
                        } else {
                            "${height}p"
                        }
                        qualities.add(
                            QualityLevel(
                                url = qualityUrl,
                                label = label,
                                bitrate = lastBitrate ?: 0,
                                width = resolution.first,
                                height = resolution.second
                            )
                        )
                    } else {
                        // Audio-only variant (no RESOLUTION tag)
                        qualities.add(
                            QualityLevel(
                                url = qualityUrl,
                                label = "Audio Only",
                                bitrate = lastBitrate ?: 0,
                                width = 0,
                                height = 0
                            )
                        )
                    }

                    lastResolution = null
                    lastBitrate = null
                    lastFrameRate = null
                }
            }
        }

        // Sort qualities by resolution height (ascending)
        val sortedQualities = qualities.sortedBy { it.height }

        // Convert to map format for Flutter
        val result = mutableListOf<Map<String, Any>>()

        // Add auto quality option
        result.add(mapOf(
            "label" to "Auto",
            "url" to (sortedQualities.firstOrNull()?.url ?: ""),
            "isAuto" to true
        ))

        // Add all available qualities
        result.addAll(sortedQualities.map { quality ->
            mapOf(
                "label" to quality.label,
                "url" to quality.url,
                "bitrate" to quality.bitrate,
                "width" to quality.width,
                "height" to quality.height,
                "isAuto" to false
            )
        })

        Log.d(TAG, "Parsed ${qualities.size} quality variants from HLS playlist")
        return result
    }

    private fun hasPendingVariant(
        bitrate: Int?,
        resolution: Pair<Int, Int>?,
        frameRate: Double?
    ): Boolean = bitrate != null || resolution != null || frameRate != null
}
