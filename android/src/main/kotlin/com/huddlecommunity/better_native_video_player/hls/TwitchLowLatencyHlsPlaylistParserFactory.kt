package com.huddlecommunity.better_native_video_player.hls

import android.net.Uri
import android.util.Log
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.hls.playlist.DefaultHlsPlaylistParserFactory
import androidx.media3.exoplayer.hls.playlist.HlsMediaPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsMultivariantPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsPlaylist
import androidx.media3.exoplayer.hls.playlist.HlsPlaylistParserFactory
import androidx.media3.exoplayer.upstream.ParsingLoadable
import java.io.ByteArrayInputStream
import java.io.InputStream

/**
 * Adds Twitch low-latency support on top of media3's HLS parser.
 *
 * Twitch advertises the bleeding-edge segments the encoder is still writing via
 * a proprietary `#EXT-X-TWITCH-PREFETCH:<url>` tag at the tail of each media
 * playlist (two of them, ~1 segment apart). The web player plays these to ride
 * the live edge; media3 doesn't know the tag and silently drops it, leaving
 * playback ~2 segments (~4s) behind — the latency regression vs the old WebView
 * player.
 *
 * This factory wraps the stock parser and rewrites each prefetch line into a
 * normal `#EXTINF` segment *before* media3 parses it, so ExoPlayer treats them
 * as playable. Promoting both matches the web player's latency.
 */
@UnstableApi
class TwitchLowLatencyHlsPlaylistParserFactory(
    private val delegate: HlsPlaylistParserFactory = DefaultHlsPlaylistParserFactory(),
) : HlsPlaylistParserFactory {

    override fun createPlaylistParser(): ParsingLoadable.Parser<HlsPlaylist> =
        RewritingParser(delegate.createPlaylistParser())

    override fun createPlaylistParser(
        multivariantPlaylist: HlsMultivariantPlaylist,
        previousMediaPlaylist: HlsMediaPlaylist?,
    ): ParsingLoadable.Parser<HlsPlaylist> =
        RewritingParser(
            delegate.createPlaylistParser(multivariantPlaylist, previousMediaPlaylist),
        )

    /** Transforms the playlist text, then delegates to the real parser. */
    private class RewritingParser(
        private val inner: ParsingLoadable.Parser<HlsPlaylist>,
    ) : ParsingLoadable.Parser<HlsPlaylist> {
        override fun parse(uri: Uri, inputStream: InputStream): HlsPlaylist {
            val text = inputStream.readBytes().toString(Charsets.UTF_8)
            // Master playlists never carry the tag, so this is a no-op for them.
            val rewritten = if (text.contains(PREFETCH_TAG)) promotePrefetch(text) else text
            return inner.parse(
                uri,
                ByteArrayInputStream(rewritten.toByteArray(Charsets.UTF_8)),
            )
        }
    }

    companion object {
        private const val TAG = "TwitchLowLatency"
        private const val PREFETCH_TAG = "#EXT-X-TWITCH-PREFETCH:"
        private const val EXTINF_TAG = "#EXTINF:"
        // Twitch low-latency segments are ~2s; only used if no real segment is
        // present to copy a duration from (effectively never).
        private const val DEFAULT_SEGMENT_DURATION = "2.000"

        /**
         * Rewrites every `#EXT-X-TWITCH-PREFETCH:<url>` line into a standard
         * `#EXTINF` + URL segment, in place (the tags are already in playback
         * order at the playlist tail). Each promoted segment continues the media
         * sequence, so the live edge advances and ExoPlayer plays closer to live.
         */
        fun promotePrefetch(playlist: String): String {
            val lines = playlist.split("\n")

            // Reuse the stream's own segment duration so ExoPlayer's buffering
            // and live-offset math stay accurate.
            val duration = lines
                .lastOrNull { it.startsWith(EXTINF_TAG) }
                ?.substringAfter(EXTINF_TAG)
                ?.substringBefore(",")
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: DEFAULT_SEGMENT_DURATION

            val out = StringBuilder(playlist.length + 128)
            var promoted = 0
            for (line in lines) {
                if (line.startsWith(PREFETCH_TAG)) {
                    val url = line.substringAfter(PREFETCH_TAG).trim()
                    if (url.isNotEmpty()) {
                        out.append(EXTINF_TAG).append(duration).append(",\n")
                        out.append(url).append('\n')
                        promoted++
                    }
                } else {
                    out.append(line).append('\n')
                }
            }
            Log.d(TAG, "Promoted $promoted prefetch segment(s) at ${duration}s")
            return out.toString()
        }
    }
}
