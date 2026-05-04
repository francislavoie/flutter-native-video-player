package com.huddlecommunity.better_native_video_player.handlers

import kotlin.test.Test
import kotlin.test.assertEquals

internal class VideoPlayerQualityHandlerTest {
    @Test
    fun parseHLSQualities_includesSignedVariantUrls() {
        val playlist = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,FRAME-RATE=60.000
            index-1080p60.m3u8?token=abc&sig=123
            #EXT-X-STREAM-INF:BANDWIDTH=2200000,RESOLUTION=1280x720,FRAME-RATE=60.000
            https://video.example.test/live/720p.m3u8?token=def
        """.trimIndent()

        val qualities = VideoPlayerQualityHandler.parseHLSQualities(
            playlist,
            "https://usher.ttvnw.net/api/channel/hls/test.m3u8?allow_source=true"
        )

        assertEquals(3, qualities.size)
        assertEquals("720p60", qualities[1]["label"])
        assertEquals("https://video.example.test/live/720p.m3u8?token=def", qualities[1]["url"])
        assertEquals("1080p60", qualities[2]["label"])
        assertEquals(
            "https://usher.ttvnw.net/api/channel/hls/index-1080p60.m3u8?token=abc&sig=123",
            qualities[2]["url"]
        )
    }

    @Test
    fun parseHLSQualities_includesAudioOnlyVariants() {
        val playlist = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=160000
            audio/index.m3u8?token=audio
            #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
            360p/index.m3u8?token=video
        """.trimIndent()

        val qualities = VideoPlayerQualityHandler.parseHLSQualities(
            playlist,
            "https://video.example.test/master.m3u8"
        )

        assertEquals(3, qualities.size)
        assertEquals("Audio Only", qualities[1]["label"])
        assertEquals(0, qualities[1]["height"])
        assertEquals("https://video.example.test/audio/index.m3u8?token=audio", qualities[1]["url"])
        assertEquals("360p", qualities[2]["label"])
    }
}
