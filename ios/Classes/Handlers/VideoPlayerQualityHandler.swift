import Foundation
import AVFoundation

class VideoPlayerQualityHandler {
    static func fetchHLSQualities(from url: URL, completion: @escaping ([VideoPlayer.QualityLevel]) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data,
                  let playlist = String(data: data, encoding: .utf8)
            else {
                if let error = error {
                    NSLog("[VideoPlayer] HLS quality fetch failed: \(error.localizedDescription)")
                }
                completion([])
                return
            }

            var qualities: [VideoPlayer.QualityLevel] = []
            let lines = playlist.components(separatedBy: "\n")
            var lastBitrate: Int?
            var lastResolution: String?
            var lastFrameRate: Double?
            
            for line in lines {
                if line.contains("#EXT-X-STREAM-INF") {
                    // Extract resolution
                    if let resMatch = line.range(of: "RESOLUTION=\\d+x\\d+", options: .regularExpression) {
                        lastResolution = String(line[resMatch]).replacingOccurrences(of: "RESOLUTION=", with: "")
                    }
                    
                    // Extract bitrate
                    if let bitrateMatch = line.range(of: "BANDWIDTH=\\d+", options: .regularExpression) {
                        let bitrateStr = String(line[bitrateMatch]).replacingOccurrences(of: "BANDWIDTH=", with: "")
                        lastBitrate = Int(bitrateStr)
                    }

                    // Extract frame rate
                    if let frameRateMatch = line.range(of: "FRAME-RATE=\\d+\\.?\\d*", options: .regularExpression) {
                        let frameRateStr = String(line[frameRateMatch]).replacingOccurrences(of: "FRAME-RATE=", with: "")
                        lastFrameRate = Double(frameRateStr)
                    }
                } else if line.hasSuffix(".m3u8") {
                    // Resolve relative URLs against the base URL
                    let qualityUrl: String
                    if line.hasPrefix("http://") || line.hasPrefix("https://") {
                        qualityUrl = line
                    } else {
                        let baseUrl = url.deletingLastPathComponent()
                        if let resolvedUrl = URL(string: line, relativeTo: baseUrl)?.absoluteString {
                            qualityUrl = resolvedUrl
                        } else {
                            qualityUrl = line
                        }
                    }
                    
                    if let resolution = lastResolution {
                        let components = resolution.components(separatedBy: "x")
                        if components.count == 2,
                           let width = Int(components[0]),
                           let height = Int(components[1]) {
                            let label: String
                            if let fps = lastFrameRate {
                                label = "\(height)p\(Int(fps.rounded()))"
                            } else {
                                label = "\(height)p"
                            }
                            qualities.append(VideoPlayer.QualityLevel(
                                url: qualityUrl,
                                label: label,
                                bitrate: lastBitrate ?? 0,
                                resolution: CGSize(width: width, height: height)
                            ))
                        }
                    } else {
                        // Audio-only variant (no RESOLUTION tag). Loaded via direct
                        // URL instead of ABR hints since preferredMaximumResolution
                        // cannot force audio-only selection.
                        qualities.append(VideoPlayer.QualityLevel(
                            url: qualityUrl,
                            label: "Audio Only",
                            bitrate: lastBitrate ?? 0,
                            resolution: .zero
                        ))
                    }
                    lastResolution = nil
                    lastBitrate = nil
                    lastFrameRate = nil
                }
            }
            
            // Sort qualities by resolution height (ascending)
            let sortedQualities = qualities.sorted { $0.resolution.height < $1.resolution.height }

            // Deduplicate labels, keeping the highest-bitrate variant.
            // When Twitch returns multiple codecs (H.264, HEVC, AV1) at the
            // same resolution/fps, they share a label like "1080p60". Keeping
            // the highest bitrate ensures the best codec variant is selectable.
            var bestByLabel: [String: VideoPlayer.QualityLevel] = [:]
            for quality in sortedQualities {
                if let existing = bestByLabel[quality.label] {
                    if quality.bitrate > existing.bitrate {
                        bestByLabel[quality.label] = quality
                    }
                } else {
                    bestByLabel[quality.label] = quality
                }
            }
            let deduped = sortedQualities.filter { quality in
                guard let best = bestByLabel[quality.label] else { return false }
                return quality.url == best.url
            }

            completion(deduped)
        }.resume()
    }
}