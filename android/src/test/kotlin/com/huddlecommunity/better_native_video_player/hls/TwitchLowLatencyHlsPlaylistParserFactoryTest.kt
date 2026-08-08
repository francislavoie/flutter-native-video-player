package com.huddlecommunity.better_native_video_player.hls

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class TwitchLowLatencyHlsPlaylistParserFactoryTest {

    /**
     * Built by joining lines rather than from a raw string: `trimIndent()` runs
     * *after* interpolation, so multi-line interpolated content would drag the
     * common indent to zero and leave every template line indented — which
     * silently breaks the `startsWith` matching under test.
     */
    private fun twitchPlaylist(vararg prefetchLines: String) = (
        listOf(
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:5",
            "#EXT-X-MEDIA-SEQUENCE:1234",
            "#EXTINF:2.000,",
            "segment-1234.ts",
            "#EXTINF:2.000,",
            "segment-1235.ts",
        ) + prefetchLines
        ).joinToString("\n")

    @Test
    fun promotePrefetch_promotesOldestAndDropsNewest() {
        val playlist = twitchPlaylist(
            "#EXT-X-TWITCH-PREFETCH:https://video.example.test/segment-1236.ts",
            "#EXT-X-TWITCH-PREFETCH:https://video.example.test/segment-1237.ts",
        )

        val result = TwitchLowLatencyHlsPlaylistParserFactory.promotePrefetch(playlist, 1)

        // Oldest prefetch becomes a real segment so playback rides the edge.
        assertTrue(result.contains("#EXTINF:2.000,\nhttps://video.example.test/segment-1236.ts"))
        // Newest is still being written — dropping it is what avoids the stall.
        assertFalse(result.contains("segment-1237.ts"))
        // No proprietary tags survive into what media3 parses.
        assertFalse(result.contains("#EXT-X-TWITCH-PREFETCH:"))
    }

    @Test
    fun promotePrefetch_rewritesTargetDurationToRealSegmentCadence() {
        val playlist = twitchPlaylist(
            "#EXT-X-TWITCH-PREFETCH:https://video.example.test/segment-1236.ts"
        )

        val result = TwitchLowLatencyHlsPlaylistParserFactory.promotePrefetch(playlist, 1)

        // Twitch advertises 5 while emitting 2s segments; media3 paces playlist
        // reloads off this value, so leaving it starves the player.
        assertTrue(result.contains("#EXT-X-TARGETDURATION:2"))
        assertFalse(result.contains("#EXT-X-TARGETDURATION:5"))
    }

    @Test
    fun promotePrefetch_leavesNonTwitchPlaylistByteIdentical() {
        // The factory is installed on every HLS source, so untouched
        // pass-through for ordinary playlists is what keeps that safe.
        val playlist = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:10
            #EXTINF:9.009,
            https://cdn.example.test/segment-0.ts
        """.trimIndent()

        assertEquals(
            playlist.trimEnd(),
            TwitchLowLatencyHlsPlaylistParserFactory.promotePrefetch(playlist, 1).trimEnd(),
        )
    }

    @Test
    fun promotePrefetch_skipsEmptyPrefetchUrlWithoutEmittingSegment() {
        val playlist = twitchPlaylist(
            "#EXT-X-TWITCH-PREFETCH:",
            "#EXT-X-TWITCH-PREFETCH:https://video.example.test/segment-1236.ts",
        )

        val result = TwitchLowLatencyHlsPlaylistParserFactory.promotePrefetch(playlist, 1)

        // An empty URL must not consume the promotion budget or emit a broken
        // #EXTINF with no URI after it.
        assertTrue(result.contains("#EXTINF:2.000,\nhttps://video.example.test/segment-1236.ts"))
        assertFalse(result.contains("#EXTINF:2.000,\n#"))
        assertFalse(result.contains("#EXTINF:2.000,\n\n"))
    }

    @Test
    fun promotePrefetch_honoursMaxPromoted() {
        val playlist = twitchPlaylist(
            "#EXT-X-TWITCH-PREFETCH:https://video.example.test/segment-1236.ts",
            "#EXT-X-TWITCH-PREFETCH:https://video.example.test/segment-1237.ts",
        )

        val result = TwitchLowLatencyHlsPlaylistParserFactory.promotePrefetch(playlist, 2)

        assertTrue(result.contains("segment-1236.ts"))
        assertTrue(result.contains("segment-1237.ts"))
        assertEquals(4, Regex("#EXTINF:").findAll(result).count())
    }
}
