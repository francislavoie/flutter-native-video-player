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

            val qualities = mutableListOf<QualityLevel>()
            val lines = playlist.lines()
            var lastBitrate: Int? = null
            var lastResolution: Pair<Int, Int>? = null
            var lastFrameRate: Double? = null

            for (line in lines) {
                when {
                    line.contains("#EXT-X-STREAM-INF") -> {
                        // Extract resolution
                        val resolutionMatch = Regex("RESOLUTION=(\\d+)x(\\d+)").find(line)
                        if (resolutionMatch != null) {
                            val width = resolutionMatch.groupValues[1].toInt()
                            val height = resolutionMatch.groupValues[2].toInt()
                            lastResolution = width to height
                        }

                        // Extract bitrate
                        val bitrateMatch = Regex("BANDWIDTH=(\\d+)").find(line)
                        lastBitrate = bitrateMatch?.groupValues?.get(1)?.toInt()

                        // Extract frame rate
                        val frameRateMatch = Regex("FRAME-RATE=(\\d+\\.?\\d*)").find(line)
                        lastFrameRate = frameRateMatch?.groupValues?.get(1)?.toDouble()
                    }
                    line.endsWith(".m3u8") -> {
                        // Resolve relative URLs against the base URL
                        val qualityUrl = when {
                            line.startsWith("http://") || line.startsWith("https://") -> line
                            line.startsWith("/") -> {
                                val baseUri = URL(url)
                                "${baseUri.protocol}://${baseUri.host}$line"
                            }
                            else -> {
                                val baseUrl = URL(url)
                                val basePath = baseUrl.path.substringBeforeLast("/")
                                "${baseUrl.protocol}://${baseUrl.host}$basePath/$line"
                            }
                        }

                        if (lastResolution != null) {
                            val height = lastResolution!!.second
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
                                    width = lastResolution!!.first,
                                    height = lastResolution!!.second
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
            result
        } catch (e: Exception) {
            Log.e(TAG, "Error fetching HLS qualities: ${e.message}", e)
            emptyList()
        } finally {
            connection.disconnect()
        }
    }
}