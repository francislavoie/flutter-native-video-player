import MediaPlayer
import AVFoundation

// MARK: - Remote Command Manager
/// Singleton to manage MPRemoteCommandCenter ownership
/// Ensures only one VideoPlayerView owns the remote commands at a time
class RemoteCommandManager {
    static let shared = RemoteCommandManager()

    /// Track which view currently owns the remote commands
    private var currentOwnerViewId: Int64?

    /// Lock to prevent race conditions during ownership transfer
    private let lock = NSLock()

    private init() {}

    /// Check if a specific view is the current owner
    func isOwner(_ viewId: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentOwnerViewId == viewId
    }

    /// Set a new owner for remote commands
    func setOwner(_ viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        currentOwnerViewId = viewId
    }

    /// Clear ownership (e.g., when owner is disposed)
    func clearOwner(_ viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if currentOwnerViewId == viewId {
            currentOwnerViewId = nil
        }
    }

    /// Get the current owner view ID
    func getCurrentOwner() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return currentOwnerViewId
    }

    /// Remove all remote command targets
    func removeAllTargets() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
    }

    /// Atomically set owner and remove all targets
    /// This prevents race conditions when multiple views try to register concurrently
    func atomicallySetOwnerAndRemoveTargets(_ viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        currentOwnerViewId = viewId
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
    }
}

extension VideoPlayerView {
    /// Sets up the Now Playing info for the Control Center and Lock Screen
    func setupNowPlayingInfo(mediaInfo: [String: Any]) {

        // Only activate audio session if the player is alive — a stale
        // invocation after dispose would steal audio focus from other apps.
        guard player != nil else { return }

        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
        }

        var nowPlayingInfo: [String: Any] = [:]

        // --- Core metadata ---
        if let title = mediaInfo["title"] as? String {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }

        if let subtitle = mediaInfo["subtitle"] as? String {
            nowPlayingInfo[MPMediaItemPropertyArtist] = subtitle
        }

        if let album = mediaInfo["album"] as? String {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        }

        // --- Live stream flag ---
        // Tell the system this is a live broadcast. Lock screen and Control
        // Center hide the scrubber / elapsed-time indicator and show "LIVE"
        // instead — which is correct UX and lets the system skip meaningless
        // per-second elapsed-time updates.
        let isLive = player?.currentItem?.duration.isIndefinite ?? true
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = isLive

        // --- Playback duration & elapsed time (VOD only) ---
        // AVPlayerItem.duration, not asset.duration — the synchronous AVAsset
        // property is deprecated since iOS 16 and can block on network assets;
        // the item's duration is already resolved once playback is ready.
        if !isLive, let duration = player?.currentItem?.duration {
            let durationSeconds = CMTimeGetSeconds(duration)
            if durationSeconds.isFinite {
                nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = durationSeconds
            }
        }

        if !isLive, let currentTime = player?.currentTime() {
            let elapsedSeconds = CMTimeGetSeconds(currentTime)
            if elapsedSeconds.isFinite {
                nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedSeconds
            }
        }

        // --- Playback rate (0 = paused, 1 = playing) ---
        let playbackRate = player?.rate ?? 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate

        // --- Commit initial metadata immediately (before artwork loads) ---
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

        // --- Artwork ---
        if let artworkUrlString = mediaInfo["artworkUrl"] as? String,
           let artworkUrl = URL(string: artworkUrlString) {

            // If we already cached artwork for this URL, use it immediately
            if artworkUrlString == cachedArtworkUrl, let cached = cachedArtwork {
                nowPlayingInfo[MPMediaItemPropertyArtwork] = cached
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            }

            // Load (or re-load) artwork asynchronously
            loadArtwork(from: artworkUrl) { [weak self] image in
                guard let self = self,
                      let image = image
                else {
                    return
                }

                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                    image
                }
                self.cachedArtwork = artwork
                self.cachedArtworkUrl = artworkUrlString

                // Read the CURRENT nowPlayingInfo so we don't overwrite
                // metadata that was set between the async load starting and finishing
                var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                updatedInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
            }
        }

        // --- Setup remote commands (if not already done) ---
        setupRemoteCommandCenter()
    }

    /// Loads artwork image from URL
    private func loadArtwork(from url: URL, completion: @escaping (UIImage?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let image = UIImage(data: data) else {
                completion(nil)
                return
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
        .resume()
    }

    /// Sets up remote command center for Control Center controls
    /// Only registers if this view should be the owner
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Check if we've already registered handlers for this view
        // If so, skip the registration to avoid clearing and re-adding targets
        // This prevents iOS from clearing Now Playing info
        if hasRegisteredRemoteCommands {
            // We've registered before - check if we're still the owner
            if RemoteCommandManager.shared.isOwner(viewId) {
                return
            } else if RemoteCommandManager.shared.getCurrentOwner() == nil {
                // Targets may have been intentionally preserved while owner
                // was cleared for PiP; reclaim ownership without churn.
                RemoteCommandManager.shared.setOwner(viewId)
                return
            } else {
                // Another view owns the global targets now, so re-register
                // below to point remote commands at this view again.
                hasRegisteredRemoteCommands = false
            }
        }


        // Atomically take ownership and clear all existing targets
        // This prevents race conditions when multiple views try to register concurrently
        RemoteCommandManager.shared.atomicallySetOwnerAndRemoveTargets(viewId)
        hasRegisteredRemoteCommands = true

        // --- Play ---
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }

            // Only handle if we still own the remote commands
            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                return .commandFailed
            }

            // Ensure audio session is active before resuming playback
            // This is critical after interruptions (e.g., phone calls)
            self.prepareAudioSession()

            // Mirror handlePlay — a stale flag from an earlier in-app pause
            // would make the next silent stall read as a user pause and
            // block recovery.
            self.userRequestedPause = false
            self.player?.play()
            self.sendEvent("play")
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        // --- Pause ---
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }

            // Only handle if we still own the remote commands
            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                return .commandFailed
            }

            // Mirror handlePause — without this a lock-screen pause is
            // classified as a silent stall and recovery force-resumes it.
            self.userRequestedPause = true
            self.player?.pause()
            self.sendEvent("pause")
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        // --- Skip forward/backward ---
        let isLive = player?.currentItem?.duration.isIndefinite ?? true
        commandCenter.skipForwardCommand.isEnabled = !isLive
        commandCenter.skipBackwardCommand.isEnabled = !isLive
        guard !isLive else {
            return
        }

        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.preferredIntervals = [15]

        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self = self,
                  let skipEvent = event as? MPSkipIntervalCommandEvent,
                  let player = self.player
            else {
                return .commandFailed
            }

            // Only handle if we still own the remote commands
            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                return .commandFailed
            }

            let currentTime = player.currentTime()
            let newTime = CMTimeAdd(currentTime, CMTime(seconds: skipEvent.interval, preferredTimescale: 600))
            player.seek(to: newTime)
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self = self,
                  let skipEvent = event as? MPSkipIntervalCommandEvent,
                  let player = self.player
            else {
                return .commandFailed
            }

            // Only handle if we still own the remote commands
            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                return .commandFailed
            }

            let currentTime = player.currentTime()
            let newTime = CMTimeSubtract(currentTime, CMTime(seconds: skipEvent.interval, preferredTimescale: 600))
            player.seek(to: max(newTime, .zero))
            self.updateNowPlayingPlaybackTime()
            return .success
        }


        // Verify remote commands are enabled
    }

    /// Updates playback time and rate dynamically (e.g., every second or on state change)
    func updateNowPlayingPlaybackTime() {
        guard let player = player else {
            return
        }

        let isPlaying = player.rate > 0

        // Only allow updates if this view owns the remote commands
        // This prevents multiple views from fighting over Now Playing info
        guard RemoteCommandManager.shared.isOwner(viewId) else {
            if isPlaying {
            }
            return
        }

        let isLive = player.currentItem?.duration.isIndefinite ?? true

        // For live streams the lock screen shows "LIVE" — no elapsed-time
        // field is needed, and rewriting MPNowPlayingInfoCenter every second
        // is pure noise. Only rate writes are still useful (play/pause state).
        if isLive {
            var nowPlayingInfo =
                MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            if (nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Float)
                == player.rate
            {
                return
            }
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            return
        }

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let currentTime = player.currentTime()
        let elapsedSeconds = CMTimeGetSeconds(currentTime)
        if elapsedSeconds.isFinite {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedSeconds
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}
