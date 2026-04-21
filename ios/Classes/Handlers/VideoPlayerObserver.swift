import AVFoundation
import Foundation

extension VideoPlayerView {
    /// Adds item-level KVO observers and notification observers to a player item.
    /// Use this when replacing an item mid-session (e.g., stall recovery) where
    /// player-level observers are already registered.
    func addItemObservers(to item: AVPlayerItem) {
        // Clear per-item error latches so each new item starts clean. Can't
        // rely solely on the .readyToPlay branch — an item that fails during
        // manifest load transitions .unknown → .failed directly and would
        // otherwise inherit the previous item's suppression flag.
        errorEmittedForCurrentItem = false
        lastErrorStatusCode = 0

        item.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
        item.addObserver(self, forKeyPath: "playbackBufferEmpty", options: [.new], context: nil)
        item.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: [.new], context: nil)
        item.addObserver(self, forKeyPath: "playbackBufferFull", options: [.new], context: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemFailedToPlay),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidStall),
            name: AVPlayerItem.playbackStalledNotification,
            object: item
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemNewErrorLogEntry),
            name: .AVPlayerItemNewErrorLogEntry,
            object: item
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(videoDidEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    /// Adds all observers (item-level + player-level) for initial setup.
    /// Player-level observers are only added once per view lifetime via hasPlayerObservers guard.
    func addObservers(to item: AVPlayerItem) {
        addItemObservers(to: item)

        // Player-level observers should only be added once. Calling addObservers
        // multiple times (e.g., on re-load) would otherwise register duplicates,
        // causing double event emission.
        if !hasPlayerObservers {
            player?.addObserver(self, forKeyPath: "timeControlStatus", options: [.new, .old], context: nil)
            player?.addObserver(self, forKeyPath: "externalPlaybackActive", options: [.new, .initial], context: nil)
            hasPlayerObservers = true
        }

        // Audio route change is a global notification — only need one observer per view
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    public override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        // Handle AVPlayerItem observations
        if let item = object as? AVPlayerItem {
            // Ignore callbacks from a replaced/stale item to prevent phantom state changes
            guard item === player?.currentItem else { return }
            switch keyPath {
            case "status":
                switch item.status {
                case .readyToPlay:
                    // Only send isInitialized for new players, not for shared players
                    // Shared players already sent their state in the init
                    if !isSharedPlayer {
                        sendEvent("isInitialized")
                    }
                case .failed:
                    emitErrorOnce(message: item.error?.localizedDescription ?? "Unknown")
                default: break
                }
            case "playbackBufferEmpty":
                // Only send buffering event when buffer is empty AND playback has stalled
                // This prevents false buffering events when the player has enough buffer to continue
                if item.isPlaybackBufferEmpty, let player = player {
                    // Only send buffering if the player is waiting to play (actually stalled)
                    // or if we're seeking (reasonForWaitingToPlay is not nil)
                    if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                        sendEvent("buffering")
                    }
                }
            case "playbackLikelyToKeepUp":
                if item.isPlaybackLikelyToKeepUp {
                    if let player = player {
                        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                            // Buffer is ready but player is stuck waiting — seek to
                            // live edge to force video decoder keyframe re-sync, then play.
                            seekToLiveEdgeAndPlay()
                        } else if player.rate > 0 && player.timeControlStatus == .playing {
                            sendEvent("play")
                        } else if player.timeControlStatus == .paused && player.reasonForWaitingToPlay == nil {
                            if !isPipCurrentlyActive {
                                sendEvent("pause")
                            }
                        }
                    }
                }
            case "playbackBufferFull":
                // Secondary recovery: playbackLikelyToKeepUp can stay false even when
                // buffer is full (confirmed Apple docs). Force playback if stuck.
                if item.isPlaybackBufferFull, let player = player,
                   player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    seekToLiveEdgeAndPlay()
                }
            default: break
            }
        } else if let observedPlayer = object as? AVPlayer, observedPlayer == player {
            // Handle AVPlayer observations
            switch keyPath {
            case "timeControlStatus":
                guard let player = player else { return }

                switch player.timeControlStatus {
                case .playing:
                    // ALWAYS update Now Playing info when playback starts
                    // This ensures media controls show the correct info whether in normal view or PiP
                    var mediaInfo = currentMediaInfo

                    // Fallback: Try to retrieve from SharedPlayerManager if not available locally
                    if mediaInfo == nil, let controllerIdValue = controllerId {
                        mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
                        if mediaInfo != nil {
                            currentMediaInfo = mediaInfo // Update local copy
                        }
                    }

                    if let mediaInfo = mediaInfo {
                        setupNowPlayingInfo(mediaInfo: mediaInfo)
                    }

                    // Enable automatic PiP when playback starts (even from native controls)
                    // This ensures auto PiP works whether the user taps Flutter controls or native controls
                    if #available(iOS 14.2, *) {
                        if let controllerIdValue = controllerId {
                            // Check if there's already a primary view for this controller
                            let hasPrimaryView = SharedPlayerManager.shared.getPrimaryViewId(for: controllerIdValue) != nil

                            if !hasPrimaryView {
                                // No primary view set yet - this means the user started playback via native controls
                                // Set THIS view as primary
                                SharedPlayerManager.shared.setPrimaryView(viewId, for: controllerIdValue)
                            }

                            // Check if THIS view is the primary view for this controller
                            if SharedPlayerManager.shared.isPrimaryView(viewId, for: controllerIdValue) {
                                // For shared players, check the shared settings instead of instance variable
                                // This ensures the second view uses the same PiP settings as the first view
                                let shouldEnableAutoPiP: Bool
                                if let sharedSettings = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue) {
                                    shouldEnableAutoPiP = sharedSettings.canStartPictureInPictureAutomatically
                                } else {
                                    shouldEnableAutoPiP = canStartPictureInPictureAutomatically
                                }

                                if shouldEnableAutoPiP {
                                    SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)

                                    // Eagerly create the PiP controller so it's warmed up
                                    // for background PiP (freshly created controllers may
                                    // not be ready for immediate startPictureInPicture).
                                    if #available(iOS 14.0, *) {
                                        ensurePipController()
                                    }

                                    // Ensure media info is set again after enabling PiP
                                    // This guarantees media controls work correctly in PiP mode
                                    if let mediaInfo = currentMediaInfo {
                                        setupNowPlayingInfo(mediaInfo: mediaInfo)
                                    }
                                }
                            }
                        }
                    }

                    sendEvent("play")
                case .paused:
                    if player.reasonForWaitingToPlay == nil && !isPipCurrentlyActive {
                        // With automaticallyWaitsToMinimizeStalling = false,
                        // a silent buffer exhaustion drops rate to 0 here
                        // rather than going through .waitingToPlayAtSpecifiedRate.
                        // Inspect the item's buffer state so stall recovery
                        // engages — but skip the check when the user just
                        // hit pause, since a tight live buffer can read as
                        // "not likely to keep up" even on a deliberate pause.
                        let item = player.currentItem
                        let stalled = !userRequestedPause
                            && (item?.isPlaybackBufferEmpty == true
                                || item?.isPlaybackLikelyToKeepUp == false)
                        if stalled, let item = item, item.status != .failed {
                            sendEvent("buffering")
                        } else {
                            sendEvent("pause")
                        }
                    }
                case .waitingToPlayAtSpecifiedRate:
                    // With automaticallyWaitsToMinimizeStalling = false (set for live),
                    // the reason is .evaluatingBufferingRate, never .toMinimizeStalls.
                    // Send buffering for any waiting state to ensure Dart knows we're stalled.
                    sendEvent("buffering")
                @unknown default:
                    break
                }
            case "externalPlaybackActive":
                guard let player = player else { return }
                let isActive = player.isExternalPlaybackActive

                if isActive {
                    // When AirPlay connects, try to get device name with multiple retry attempts

                    // Try to get device name immediately
                    let deviceName = getAirPlayDeviceName()

                    // Send initial event (might have deviceName or might be nil)
                    var eventData: [String: Any] = ["isConnected": isActive, "isConnecting": false]
                    if let deviceName = deviceName {
                        eventData["deviceName"] = deviceName
                    }

                    // Send through per-view event channel (legacy)
                    sendEvent("airPlayConnectionChanged", data: eventData)

                    // Send through controller-level event channel (persists when views disposed)
                    if let controllerIdValue = controllerId {
                        SharedPlayerManager.shared.sendControllerEvent(
                            "airPlayConnectionChanged",
                            data: eventData,
                            for: controllerIdValue
                        )
                    }

                    // If device name is nil, retry multiple times with increasing delays
                    if deviceName == nil {
                        retryGetAirPlayDeviceName(attempt: 1, maxAttempts: 4)
                    }
                } else {
                    // Disconnected from AirPlay
                    var eventData: [String: Any] = ["isConnected": false, "isConnecting": false]

                    // Send through per-view event channel (legacy)
                    sendEvent("airPlayConnectionChanged", data: eventData)

                    // Send through controller-level event channel (persists when views disposed)
                    if let controllerIdValue = controllerId {
                        SharedPlayerManager.shared.sendControllerEvent(
                            "airPlayConnectionChanged",
                            data: eventData,
                            for: controllerIdValue
                        )
                    }
                }
            default: break
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    @objc func playerItemDidStall(notification: Notification) {
        sendEvent("buffering")
        // Attempt recovery after brief delay — seek to live edge to force
        // video decoder keyframe re-sync (plain play() can leave video frozen).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, let player = self.player else { return }
            if player.timeControlStatus != .playing {
                self.seekToLiveEdgeAndPlay()
            }
        }
    }

    /// Seeks to the live edge and starts playback. Forces both audio and video
    /// decoders to re-sync to a fresh keyframe, preventing frozen-video-with-audio.
    /// Guarded against re-entrancy — multiple recovery paths can fire concurrently
    /// and overlapping seeks would cause thrashing.
    func seekToLiveEdgeAndPlay() {
        guard !isRecoveringFromStall else { return }
        isRecoveringFromStall = true

        guard let player = player, let item = player.currentItem else {
            player?.play()
            isRecoveringFromStall = false
            return
        }

        if let lastRange = item.seekableTimeRanges.last?.timeRangeValue {
            // Seek to ~2s before the live edge to leave buffer headroom.
            // Seeking to the exact end leaves zero buffer ahead, causing
            // immediate re-buffering on any network fluctuation.
            let liveEdge = CMTimeRangeGetEnd(lastRange)
            let buffer = CMTimeMake(value: 2, timescale: 1)
            let target = CMTimeSubtract(liveEdge, buffer)
            let seekTarget = CMTimeMaximum(target, lastRange.start)
            player.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.player?.play()
                self?.isRecoveringFromStall = false
            }
        } else if isPipCurrentlyActive {
            // During PiP, don't replace the AVPlayerItem — item replacement
            // can cause PiP to close. Just try to resume playback and let
            // the existing item recover.
            player.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isRecoveringFromStall = false
            }
        } else {
            // seekableTimeRanges is empty — the player is too far behind the live
            // window or the manifest hasn't loaded yet. Replace the AVPlayerItem
            // to force a full re-fetch of the manifest and segments.
            if let asset = item.asset as? AVURLAsset {
                let freshItem = AVPlayerItem(asset: AVURLAsset(url: asset.url))
                self.removeItemObservers(from: item)
                player.replaceCurrentItem(with: freshItem)
                // Only add item-level observers — player-level are already registered
                self.addItemObservers(to: freshItem)
                player.play()
            } else {
                player.play()
            }
            // Delay clearing the re-entrancy guard so KVO callbacks from the
            // fresh item don't immediately re-trigger recovery while it loads.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isRecoveringFromStall = false
            }
        }
    }

    /// Removes KVO observers and notification observers from a player item.
    /// Must mirror exactly what `addItemObservers(to:)` registers.
    func removeItemObservers(from item: AVPlayerItem) {
        item.removeObserver(self, forKeyPath: "status")
        item.removeObserver(self, forKeyPath: "playbackBufferEmpty")
        item.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
        item.removeObserver(self, forKeyPath: "playbackBufferFull")
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        NotificationCenter.default.removeObserver(self, name: AVPlayerItem.playbackStalledNotification, object: item)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemNewErrorLogEntry, object: item)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item)
    }

    @objc func playerItemFailedToPlay(notification: Notification) {
        let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
            .localizedDescription ?? "Unknown error"
        emitErrorOnce(message: message)
    }

    @objc func playerItemNewErrorLogEntry(notification: Notification) {
        guard let item = notification.object as? AVPlayerItem,
              let errorLog = item.errorLog(),
              let lastEvent = errorLog.events.last else { return }
        lastErrorStatusCode = lastEvent.errorStatusCode
        NSLog("[VideoPlayer] Error log: status=\(lastEvent.errorStatusCode) domain=\(lastEvent.errorDomain) comment=\(lastEvent.errorComment ?? "none") URI=\(lastEvent.uri ?? "none")")
    }

    /// Emits an "error" event at most once per AVPlayerItem. AVFoundation
    /// fires both `item.status = .failed` and `AVPlayerItemFailedToPlayToEndTime`
    /// for the same underlying failure; without this guard Dart runs the
    /// recovery ladder twice and burns a refresh-attempt slot.
    func emitErrorOnce(message: String) {
        if errorEmittedForCurrentItem { return }
        errorEmittedForCurrentItem = true
        var data: [String: Any] = ["message": message]
        if lastErrorStatusCode != 0 { data["statusCode"] = lastErrorStatusCode }
        sendEvent("error", data: data)
    }

    @objc func videoDidEnd() {
        if enableLooping {
            // For smooth looping, seek to beginning and continue playing
            player?.seek(to: .zero) { [weak self] finished in
                if finished {
                    // Continue playing for seamless loop
                    self?.player?.play()
                }
            }
            // Don't send completed event when looping to match Android behavior
            // (Android with REPEAT_MODE_ONE doesn't reach STATE_ENDED)
        } else {
            // Reset video to the beginning and pause
            player?.seek(to: .zero)
            player?.pause()
            sendEvent("completed")
        }
    }

    // MARK: - AirPlay Route Detection
    //
    // Per-view AVRouteDetector was removed — all route detection is owned by
    // SharedPlayerManager.startAirPlayRouteDetection(). Apple warns the
    // detector "significantly increases power consumption", so a single
    // shared instance is preferred over one per view.

    /// Gets the name of the currently connected AirPlay device
    func getAirPlayDeviceName() -> String? {
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        for output in currentRoute.outputs {
            if output.portType == .airPlay {
                return output.portName
            }
        }
        return nil
    }

    /// Retries getting the AirPlay device name with exponential backoff
    ///
    /// This function recursively retries getting the device name because iOS sometimes
    /// takes time to update the audio route when AirPlay video streaming starts.
    ///
    /// - Parameters:
    ///   - attempt: Current attempt number (1-based)
    ///   - maxAttempts: Maximum number of retry attempts
    func retryGetAirPlayDeviceName(attempt: Int, maxAttempts: Int) {
        guard attempt <= maxAttempts else {
            return
        }

        // Calculate delay with exponential backoff: 0.1s, 0.3s, 0.6s, 1.0s
        let delay: Double
        switch attempt {
        case 1: delay = 0.1
        case 2: delay = 0.3
        case 3: delay = 0.6
        default: delay = 1.0
        }


        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }

            let deviceName = self.getAirPlayDeviceName()

            if let deviceName = deviceName {
                // Success! Send event with device name
                var eventData: [String: Any] = ["isConnected": true, "isConnecting": false]
                eventData["deviceName"] = deviceName

                // Send through per-view event channel (legacy)
                self.sendEvent("airPlayConnectionChanged", data: eventData)

                // Send through controller-level event channel (persists when views disposed)
                if let controllerIdValue = self.controllerId {
                    SharedPlayerManager.shared.sendControllerEvent(
                        "airPlayConnectionChanged",
                        data: eventData,
                        for: controllerIdValue
                    )
                }
            } else if attempt < maxAttempts {
                // Try again
                self.retryGetAirPlayDeviceName(attempt: attempt + 1, maxAttempts: maxAttempts)
            } else {
                // Exhausted all retries
                // Send event without device name - the Dart caching layer will handle it
                var eventData: [String: Any] = ["isConnected": true, "isConnecting": false]

                // Send through per-view event channel (legacy)
                self.sendEvent("airPlayConnectionChanged", data: eventData)

                // Send through controller-level event channel (persists when views disposed)
                if let controllerIdValue = self.controllerId {
                    SharedPlayerManager.shared.sendControllerEvent(
                        "airPlayConnectionChanged",
                        data: eventData,
                        for: controllerIdValue
                    )
                }
            }
        }
    }

    /// Handles audio route changes to detect AirPlay device changes
    @objc func handleAudioRouteChange(notification: Notification) {

        // Log the reason for the route change
        if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt {
            let reasonString: String
            switch AVAudioSession.RouteChangeReason(rawValue: reason) {
            case .newDeviceAvailable: reasonString = "NewDeviceAvailable"
            case .oldDeviceUnavailable: reasonString = "OldDeviceUnavailable"
            case .categoryChange: reasonString = "CategoryChange"
            case .override: reasonString = "Override"
            case .wakeFromSleep: reasonString = "WakeFromSleep"
            case .noSuitableRouteForCategory: reasonString = "NoSuitableRouteForCategory"
            case .routeConfigurationChange: reasonString = "RouteConfigurationChange"
            default: reasonString = "Unknown(\(reason))"
            }
        }

        guard let player = player else { return }

        let deviceName = getAirPlayDeviceName()
        let isPlayerActive = player.isExternalPlaybackActive

        // Use same logic as initial state check:
        // We're connected if EITHER the player is using AirPlay OR device is in audio route
        let isSystemActive = deviceName != nil
        let isConnected = isPlayerActive || isSystemActive

        // Determine if we're in a connecting state:
        // - AirPlay device is present in audio route (systemActive)
        // - But player hasn't started streaming yet (!playerActive)
        // - AND we consider this "connected" at system level (isConnected)
        let isConnecting = isSystemActive && !isPlayerActive && isConnected

        // Only send events for AirPlay-related changes
        if deviceName != nil || isPlayerActive {

            var eventData: [String: Any] = [
                "isConnected": isConnected,
                "isConnecting": isConnecting
            ]
            if let deviceName = deviceName {
                eventData["deviceName"] = deviceName
            }

            // Send through per-view event channel (legacy)
            sendEvent("airPlayConnectionChanged", data: eventData)

            // Send through controller-level event channel (persists when views disposed)
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.sendControllerEvent(
                    "airPlayConnectionChanged",
                    data: eventData,
                    for: controllerIdValue
                )
            }
        } else {
        }
    }
}