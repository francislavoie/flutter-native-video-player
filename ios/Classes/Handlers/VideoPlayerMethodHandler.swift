import Flutter
import AVFoundation
import AVKit

import MediaPlayer

// Add reference to VideoPlayerView in the extension scope
extension VideoPlayerView {

    func handleLoad(call: FlutterMethodCall, result: @escaping FlutterResult) {

        guard let arguments = call.arguments as? [String: Any],
              let urlString = arguments["url"] as? String,
              let url = URL(string: urlString)
        else {
            let error = FlutterError(code: "INVALID_URL", message: "Invalid URL provided", details: nil)
            result(error)
            return
        }

        // A fresh stream load always implies playback intent.
        userRequestedPause = false

        let autoPlay = arguments["autoPlay"] as? Bool ?? false
        let headers = arguments["headers"] as? [String: String]
        let mediaInfo = arguments["mediaInfo"] as? [String: Any]
        let drmConfig = arguments["drmConfig"] as? [String: Any]

        // Store media info for Now Playing. Merge with existing rather than
        // replacing outright — setMediaInfo may have already delivered the
        // artworkUrl before this loadUrl call, and the controller's initial
        // mediaInfo omits null fields.
        if let mediaInfo = mediaInfo {
            if let existing = currentMediaInfo,
               mediaInfo["artworkUrl"] == nil,
               let existingArtwork = existing["artworkUrl"] {
                var merged = mediaInfo
                merged["artworkUrl"] = existingArtwork
                currentMediaInfo = merged
            } else {
                currentMediaInfo = mediaInfo
            }

            // Also store in SharedPlayerManager to persist across view recreations
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setMediaInfo(for: controllerIdValue, mediaInfo: currentMediaInfo!)
            }
        }

        // Store master playlist URL for reloading after audio-only playback
        masterPlaylistUrl = url

        // Reset stall recovery guard — a new load invalidates any in-flight seek.
        isRecoveringFromStall = false

        sendEvent("loading")

        // Determine if this is likely an HLS stream
        let isHls = isHlsUrl(url)

        // Fetch qualities (async) only for HLS streams
        if isHls {
            VideoPlayerQualityHandler.fetchHLSQualities(from: url) { [weak self] qualities in
            guard let self = self else { return }

            self.qualityLevels = qualities

            // Convert to Flutter format
            var result: [[String: Any]] = []

            // Add auto quality option
            result.append([
                "label": "Auto",
                "url": qualities.first?.url ?? "",
                "isAuto": true
            ])

            // Add all available qualities
            result.append(contentsOf: qualities.map { quality in
                [
                    "label": quality.label,
                    "url": quality.url,
                    "bitrate": quality.bitrate,
                    "width": Int(quality.resolution.width),
                    "height": Int(quality.resolution.height),
                    "isAuto": false
                ]
            })

            // Send qualities to Flutter
            self.availableQualities = result

            // Store in SharedPlayerManager if this is a shared player
            if let controllerIdValue = self.controllerId {
                SharedPlayerManager.shared.setQualities(
                    for: controllerIdValue,
                    qualities: result,
                    qualityLevels: qualities
                )
            }

            // Send qualityChange event to notify Flutter that qualities are loaded
            if !result.isEmpty, let defaultQuality = result.first {
                self.sendEvent("qualityChange", data: [
                    "url": defaultQuality["url"] as? String ?? "",
                    "label": defaultQuality["label"] as? String ?? "Auto",
                    "isAuto": defaultQuality["isAuto"] as? Bool ?? true
                ])
            }
            }
        } else {
        }

        // --- Build player item ---
        let playerItem: AVPlayerItem
        let asset: AVURLAsset
        
        // Create asset with headers if provided
        if let headers = headers {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: url)
        }
        
        // Setup DRM if configured
        if let drmConfig = drmConfig {
            // Clean up existing DRM handler if any
            self.drmHandler?.cleanup()
            
            let drmHandler = VideoPlayerDrmHandler(drmConfig: drmConfig)
            self.drmHandler = drmHandler
            
            // Setup DRM asynchronously
            drmHandler.setupDRM(asset: asset) { [weak self] success, error in
                if let error = error {
                    // Continue with playback even if DRM setup fails
                    // The player will attempt to play and may fail later
                } else {
                }
            }
        }
        
        // Remove observers from old item before replacing
        if let oldItem = player?.currentItem {
            removeItemObservers(from: oldItem)
        }

        playerItem = AVPlayerItem(asset: asset)

        // Replace current item immediately - don't wait for HDR configuration
        // This allows the video to start loading right away
        player?.replaceCurrentItem(with: playerItem)

        // --- Set up observers for buffer status and player state ---
        addObservers(to: playerItem)

        // --- Set up periodic time observer for Now Playing elapsed time updates ---
        setupPeriodicTimeObserver()

        // --- Observe status (wait for ready) ---
        var statusObserver: NSKeyValueObservation?
        statusObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self = self else {
                return
            }

            switch item.status {
            case .readyToPlay:

                // Get duration
                let duration = item.duration
                let durationSeconds = CMTimeGetSeconds(duration)

                // Send Flutter event with duration (only if valid)
                if durationSeconds.isFinite && !durationSeconds.isNaN {
                    let totalDuration = Int(durationSeconds * 1000) // milliseconds
                    self.sendEvent("loaded", data: [
                        "duration": totalDuration
                    ])
                } else {
                    self.sendEvent("loaded")
                }

                // Set up PiP controller if available
                // Note: We need to get the player layer from the AVPlayerViewController
                // Check PiP support and send availability
                // Note: Do NOT create custom AVPictureInPictureController here
                // as it interferes with automatic PiP from AVPlayerViewController
                if #available(iOS 14.0, *) {
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        // Send availability immediately
                        self.sendEvent("pipAvailabilityChanged", data: ["isAvailable": true])
                    } else {
                        self.sendEvent("pipAvailabilityChanged", data: ["isAvailable": false])
                    }
                } else {
                    // iOS version too old for PiP
                    self.sendEvent("pipAvailabilityChanged", data: ["isAvailable": false])
                }

                // Auto play if requested
                if autoPlay {
                    // Prepare audio session, Now Playing info, and PiP before playback
                    self.prepareForPlayback()

                    // Start playback
                    self.player?.play()
                    self.player?.rate = self.desiredPlaybackSpeed
                    self.updateNowPlayingPlaybackTime()
                    // Play event will be sent automatically by timeControlStatus observer
                }

                // Release observer (avoid leaks)
                statusObserver?.invalidate()

                result(nil)

            case .failed:
                let error = item.error?.localizedDescription ?? "Unknown error"
                result(FlutterError(code: "LOAD_ERROR", message: error, details: nil))

            case .unknown:
                break

            @unknown default:
                break
            }
        }
    }


    /// Prepares the player for playback by setting up audio session, Now Playing info, and PiP
    /// This should be called before starting playback to ensure proper background audio and lock screen controls
    private func prepareForPlayback() {
        // CRITICAL: Activate audio session BEFORE calling player.play()
        // This ensures audio continues when the screen locks
        prepareAudioSession()

        // ALWAYS set media item on play to ensure this player has control
        // This is critical for both normal playback and PiP mode
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

        // Mark this view as the primary (active) view for this controller
        // This ensures automatic PiP will be enabled on THIS view, not other views
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setPrimaryView(viewId, for: controllerIdValue)
        }

        // Enable automatic PiP for this controller and disable for all others
        // Only if automatic PiP was requested in creation params
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId {
                // Only enable if the user requested it in creation params
                let shouldEnableAutoPiP = canStartPictureInPictureAutomatically
                if shouldEnableAutoPiP {
                    SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                } else {
                }
            }
        }
    }

    func handlePlay(result: @escaping FlutterResult) {
        // Prepare audio session, Now Playing info, and PiP before playback
        prepareForPlayback()

        userRequestedPause = false
        player?.play()
        // Apply the desired playback speed
        player?.rate = desiredPlaybackSpeed
        updateNowPlayingPlaybackTime()
        // Play event will be sent automatically by timeControlStatus observer
        result(nil)
    }

    func handlePause(result: @escaping FlutterResult) {
        userRequestedPause = true
        player?.pause()
        updateNowPlayingPlaybackTime()

        // DON'T disable automatic PiP on pause anymore
        // The system will handle when to trigger automatic PiP based on playback state
        // Disabling it here causes issues when exiting manual PiP (video might pause during transition)
        // and prevents automatic PiP from working afterward
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId {
            }
        }

        // Pause event will be sent automatically by timeControlStatus observer
        result(nil)
    }

    func handleSeekTo(call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let args = call.arguments as? [String: Any],
           let milliseconds = args["milliseconds"] as? Int {
            let seconds = Double(milliseconds) / 1000.0
            player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000)) { [weak self] _ in
                self?.sendEvent("seek", data: ["position": milliseconds])
                self?.updateNowPlayingPlaybackTime()
            }
        }
        result(nil)
    }

    func handleSetVolume(call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let args = call.arguments as? [String: Any],
           let volume = args["volume"] as? Double {
            player?.volume = Float(volume)
        }
        result(nil)
    }

    func handleSetSpeed(call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let args = call.arguments as? [String: Any],
           let speed = args["speed"] as? Double {

            // Store the desired speed
            desiredPlaybackSpeed = Float(speed)


            // If currently playing, apply the speed immediately
            if player?.timeControlStatus == .playing {
                player?.rate = Float(speed)
            } else {
            }

            sendEvent("speedChange", data: ["speed": speed])
            result(nil)
        } else {
            result(FlutterError(code: "INVALID_SPEED", message: "Invalid speed value", details: nil))
        }
    }

    func handleSetLooping(call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let args = call.arguments as? [String: Any],
           let looping = args["looping"] as? Bool {

            // Update the enableLooping property
            enableLooping = looping

            result(nil)
        } else {
            result(FlutterError(code: "INVALID_LOOPING", message: "Invalid looping value", details: nil))
        }
    }

    // Auto-quality handling
    
    func handleSetQuality(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let qualityInfo = args["quality"] as? [String: Any] else {
            result(FlutterError(code: "INVALID_QUALITY", message: "Invalid quality data", details: nil))
            return
        }

        let isAuto = qualityInfo["isAuto"] as? Bool ?? false

        if isAuto {
            // If currently on audio-only (different item), reload the master playlist
            if let masterUrl = masterPlaylistUrl,
               let currentUrl = (player?.currentItem?.asset as? AVURLAsset)?.url,
               currentUrl != masterUrl {
                if let oldItem = player?.currentItem { removeItemObservers(from: oldItem) }
                let item = AVPlayerItem(url: masterUrl)
                player?.replaceCurrentItem(with: item)
                addItemObservers(to: item)
                configureLiveItem()
                if #available(iOS 14.2, *), canStartPictureInPictureAutomatically {
                    pipController?.canStartPictureInPictureAutomaticallyFromInline = true
                }
                playWhenReady()
            }

            // Remove bitrate/resolution constraints — AVPlayer uses native ABR
            player?.currentItem?.preferredPeakBitRate = 0
            player?.currentItem?.preferredMaximumResolution = .zero

            sendEvent("qualityChange", data: [
                "url": "",
                "label": "Auto",
                "isAuto": true
            ])
        } else {
            let width = qualityInfo["width"] as? Int ?? 0
            let height = qualityInfo["height"] as? Int ?? 0
            let urlString = qualityInfo["url"] as? String ?? ""

            if width == 0 && height == 0, let variantUrl = URL(string: urlString) {
                // Audio-only: load the variant URL directly since ABR hints
                // (preferredMaximumResolution) cannot force audio-only selection.
                if let oldItem = player?.currentItem { removeItemObservers(from: oldItem) }
                let item = AVPlayerItem(url: variantUrl)
                player?.replaceCurrentItem(with: item)
                addItemObservers(to: item)
                configureLiveItem()
                // Disable auto background PiP so audio continues in Dynamic Island
                if #available(iOS 14.2, *) {
                    pipController?.canStartPictureInPictureAutomaticallyFromInline = false
                }
                playWhenReady()
            } else {
                // Video quality: if currently on audio-only (different item),
                // reload the master playlist first so ABR hints work.
                var replacedItem = false
                if let masterUrl = masterPlaylistUrl,
                   let currentUrl = (player?.currentItem?.asset as? AVURLAsset)?.url,
                   currentUrl != masterUrl {
                    if let oldItem = player?.currentItem { removeItemObservers(from: oldItem) }
                    let item = AVPlayerItem(url: masterUrl)
                    player?.replaceCurrentItem(with: item)
                    addItemObservers(to: item)
                    configureLiveItem()
                    // Restore auto background PiP (was disabled for audio-only)
                    if #available(iOS 14.2, *), canStartPictureInPictureAutomatically {
                        pipController?.canStartPictureInPictureAutomaticallyFromInline = true
                    }
                    replacedItem = true
                }

                // Constrain resolution, let AVPlayer pick the best bitrate variant
                player?.currentItem?.preferredPeakBitRate = 0
                player?.currentItem?.preferredMaximumResolution = CGSize(width: width, height: height)

                if replacedItem {
                    playWhenReady()
                }
            }

            sendEvent("qualityChange", data: [
                "url": urlString,
                "label": qualityInfo["label"] as? String ?? "",
                "isAuto": false
            ])
        }

        result(nil)
    }

    /// Starts playback once the current item is ready. Calling play()
    /// immediately after replaceCurrentItem is unreliable — the item may
    /// not be ready yet.
    private func playWhenReady() {
        playWhenReadyObserver?.invalidate()
        playWhenReadyObserver = nil
        guard let item = player?.currentItem else { return }
        if item.status == .readyToPlay {
            player?.play()
            return
        }
        playWhenReadyObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .readyToPlay {
                self.player?.play()
                self.playWhenReadyObserver = nil
            } else if item.status == .failed {
                self.playWhenReadyObserver = nil
            }
        }
    }

    /// Applies live playback settings to the current player item.
    private func configureLiveItem() {
        player?.automaticallyWaitsToMinimizeStalling = false
        player?.currentItem?.preferredForwardBufferDuration = 0
        // Apple-recommended for live: don't refresh seekable ranges while
        // paused. Saves bandwidth/battery; the live edge resyncs on resume.
        // Safe with the current config because the forward-buffer cap is the
        // system default (~20-60s) and silent-stall detection in the .paused
        // KVO branch will engage stall recovery if a buffer-empty unpause
        // ever materializes — so the old pause loop can't recur silently.
        player?.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        if #available(iOS 13.0, *) {
            player?.currentItem?.automaticallyPreservesTimeOffsetFromLive = true
        }
    }

    func handleConfigureForLivePlayback(call: FlutterMethodCall, result: @escaping FlutterResult) {
        configureLiveItem()
        result(nil)
    }

    func handleSeekToLiveEdge(result: @escaping FlutterResult) {
        guard let item = player?.currentItem else {
            result(nil)
            return
        }
        guard let lastRange = item.seekableTimeRanges.last?.timeRangeValue else {
            result(nil)
            return
        }
        // Seek to ~2s before the live edge to leave buffer headroom.
        // Seeking to the exact end leaves zero buffer ahead, causing
        // immediate re-buffering on any network fluctuation.
        let liveEdge = CMTimeRangeGetEnd(lastRange)
        let buffer = CMTimeMake(value: 2, timescale: 1)
        let target = CMTimeSubtract(liveEdge, buffer)
        let seekTarget = CMTimeMaximum(target, lastRange.start)
        player?.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            result(nil)
        }
    }

    func handleGetLatencyToLive(result: @escaping FlutterResult) {
        guard let currentDate = player?.currentItem?.currentDate() else {
            result(nil)
            return
        }
        let latency = Date().timeIntervalSince(currentDate)
        result(max(0.0, latency))
    }

    func handleSetShowNativeControls(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let show = arguments["show"] as? Bool else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
        }

        // Set controls visibility for embedded player
        playerViewController.showsPlaybackControls = show

        // Also set for fullscreen player if it exists
        if let fullscreenVC = fullscreenPlayerViewController {
            fullscreenVC.showsPlaybackControls = show
        }

        result(nil)
    }

    func handleIsAirPlayAvailable(result: @escaping FlutterResult) {
        // Check if AirPlay is supported on this device
        // AVRoutePickerView requires iOS 11.0+
        if #available(iOS 11.0, *) {
            // AirPlay is available on iOS 11.0+
            // Note: This checks if the device supports AirPlay, not if AirPlay devices
            // are currently available on the network (which changes dynamically)
            result(true)
        } else {
            // AirPlay requires iOS 11.0+
            result(false)
        }
    }

    func handleShowAirPlayPicker(result: @escaping FlutterResult) {
        // Check iOS version - AVRoutePickerView requires iOS 11.0+
        guard #available(iOS 11.0, *) else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "AirPlay picker requires iOS 11.0+", details: nil))
            return
        }

        // Find the root view controller. UIApplication.keyWindow is deprecated
        // in iOS 13+ and returns nil on multi-scene iPadOS; iterate connected
        // scenes to find the active key window.
        guard let rootViewController = Self.activeKeyWindow()?.rootViewController else {
            result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "Could not find root view controller", details: nil))
            return
        }

        // Create an AVRoutePickerView
        let routePickerView = AVRoutePickerView()
        routePickerView.frame = CGRect(x: 0, y: 0, width: 0, height: 0)
        routePickerView.isHidden = true

        // Add it temporarily to the view hierarchy
        rootViewController.view.addSubview(routePickerView)

        // Find the button inside the route picker view and simulate a tap
        DispatchQueue.main.async {
            for subview in routePickerView.subviews {
                if let button = subview as? UIButton {
                    button.sendActions(for: .touchUpInside)
                    break
                }
            }

            // Clean up - remove the route picker after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                routePickerView.removeFromSuperview()
            }

            result(nil)
        }
    }

    func handleDisconnectAirPlay(result: @escaping FlutterResult) {
        guard let player = player else {
            result(FlutterError(code: "NO_PLAYER", message: "Player not initialized", details: nil))
            return
        }

        // Check if currently connected to AirPlay
        guard player.isExternalPlaybackActive else {
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected to AirPlay", details: nil))
            return
        }

        // Disable external playback to disconnect from AirPlay
        // This will stop sending video to the AirPlay device
        player.usesExternalPlaybackWhileExternalScreenIsActive = false

        // Re-enable it after a short delay so AirPlay can be used again later
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
        }

        result(nil)
    }

    func handleStartAirPlayDetection(result: @escaping FlutterResult) {
        if #available(iOS 11.0, *) {
            SharedPlayerManager.shared.startAirPlayRouteDetection()
            result(nil)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "AirPlay detection requires iOS 11.0+", details: nil))
        }
    }

    func handleStopAirPlayDetection(result: @escaping FlutterResult) {
        if #available(iOS 11.0, *) {
            SharedPlayerManager.shared.stopAirPlayRouteDetection()
            result(nil)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "AirPlay detection requires iOS 11.0+", details: nil))
        }
    }

    func handleDispose(result: @escaping FlutterResult) {

        // Remove time observer before releasing the player
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        // Pause the player first
        player?.pause()

        // Clean up DRM handler
        drmHandler?.cleanup()
        drmHandler = nil

        // Clean up remote command ownership (transfer to another view if possible)
        cleanupRemoteCommandOwnership()

        // Shared players deactivate the audio session via
        // SharedPlayerManager.removePlayer → deactivateAudioSessionIfIdle.
        // Non-shared players don't register with the manager, so deactivate
        // directly here. .notifyOthersOnDeactivation lets interrupted apps
        // resume their audio.
        if let controllerId = controllerId {
            SharedPlayerManager.shared.removePlayer(for: controllerId)
        } else {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }

        // Clear local player reference
        player = nil

        sendEvent("stopped")
        result(nil)
    }

    func handleEnterFullScreen(result: @escaping FlutterResult) {
        if let viewController = Self.activeKeyWindow()?.rootViewController {
            // Create a NEW player view controller for fullscreen
            // This prevents the embedded view from being removed from Flutter's view hierarchy
            let fullscreenPlayerViewController = AVPlayerViewController()
            fullscreenPlayerViewController.player = player
            fullscreenPlayerViewController.showsPlaybackControls = true
            fullscreenPlayerViewController.delegate = self

            // Store reference to dismiss later
            self.fullscreenPlayerViewController = fullscreenPlayerViewController

            viewController.present(fullscreenPlayerViewController, animated: true) {
                // Send event after animation completes
                self.sendEvent("fullscreenChange", data: ["isFullscreen": true])
                result(nil)
            }
        } else {
            result(FlutterError(code: "FULLSCREEN_ERROR", message: "Could not present fullscreen player", details: nil))
        }
    }

    func handleExitFullScreen(result: @escaping FlutterResult) {
        // Store the playback state before dismissing
        let wasPlaying = player?.rate != 0
        
        // Dismiss the fullscreen player view controller if it exists
        if let fullscreenVC = fullscreenPlayerViewController {
            // Release the video layer from the fullscreen VC before dismiss so the embedded view can show it again
            fullscreenVC.player = nil
            fullscreenVC.dismiss(animated: true) {
                // Clear the reference
                self.fullscreenPlayerViewController = nil
                
                // Resume playback if it was playing before
                if wasPlaying {
                    self.player?.play()
                }

                // Re-bind the player to the embedded view on the next run loop after the transition has fully finished
                DispatchQueue.main.async {
                    self.playerViewController.player = nil
                    self.playerViewController.player = self.player
                }

                self.sendEvent("fullscreenChange", data: ["isFullscreen": false])
                result(nil)
            }
        } else {
            // Fallback: dismiss the embedded player controller (shouldn't happen)
            playerViewController.dismiss(animated: true) {
                // Resume playback if it was playing before
                if wasPlaying {
                    self.player?.play()
                }
                
                self.sendEvent("fullscreenChange", data: ["isFullscreen": false])
                result(nil)
            }
        }
    }

    func handleIsPictureInPictureAvailable(result: @escaping FlutterResult) {
        if #available(iOS 14.0, *) {
            // Check if PiP is supported on this device
            let isPipSupported = AVPictureInPictureController.isPictureInPictureSupported()
            result(isPipSupported)
        } else {
            // PiP requires iOS 14.0+
            result(false)
        }
    }

    func handleEnterPictureInPicture(result: @escaping FlutterResult) {
        if #available(iOS 14.0, *) {
            // Check if video is loaded and ready
            guard let player = player, let currentItem = player.currentItem else {
                result(FlutterError(code: "NO_VIDEO", message: "No video loaded.", details: nil))
                return
            }
            
            guard currentItem.status == .readyToPlay else {
                result(FlutterError(code: "NOT_READY", message: "Video is not ready to play.", details: nil))
                return
            }
            
            // Check if PiP is supported on device
            guard AVPictureInPictureController.isPictureInPictureSupported() else {
                result(FlutterError(code: "NOT_SUPPORTED", message: "Picture-in-Picture is not supported on this device.", details: nil))
                return
            }


            // Mark manual PiP as active for this controller
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: true)
            }

            // CRITICAL: Temporarily disable AVPlayerViewController's PiP while using custom controller
            // This prevents the AVPlayerViewController from starting its own PiP simultaneously
            // NOTE: We do this AFTER the checks, so it doesn't interfere with the next manual PiP attempt
            playerViewController.allowsPictureInPicturePlayback = false

            // Get or create the PiP controller for this player layer
            // Reuse existing controller if available, or create new one
            if pipController == nil {
                if let playerLayer = findPlayerLayer() {
                    pipController = try? AVPictureInPictureController(playerLayer: playerLayer)
                    pipController?.delegate = self
                } else {
                    if let controllerIdValue = controllerId {
                        SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
                    }
                    result(FlutterError(code: "NO_LAYER", message: "Could not find player layer", details: nil))
                    return
                }
            }

            // Start PiP using the controller
            // Wait for the controller to be ready with retries
            var attempt = 0
            let maxAttempts = 3
            var resultSent = false

            func sendResult(_ value: Any?) {
                guard !resultSent else { return }
                resultSent = true
                result(value)
            }

            func tryStartPip() {
                attempt += 1

                if let pipController = pipController {

                    if pipController.isPictureInPicturePossible {
                        pipController.startPictureInPicture()
                        sendResult(true)
                    } else if attempt < maxAttempts {
                        // Retry after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            guard self != nil else { return }
                            tryStartPip()
                        }
                    } else {
                        if let controllerIdValue = controllerId {
                            SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
                            // Re-enable AVPlayerViewController PiP since we're not starting
                            playerViewController.allowsPictureInPicturePlayback = false
                            if #available(iOS 14.2, *) {
                                if canStartPictureInPictureAutomatically {
                                    SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                                }
                            }
                        }
                        sendResult(FlutterError(code: "PIP_NOT_POSSIBLE", message: "Picture-in-Picture is not possible at this time. Make sure the video is playing and loaded.", details: nil))
                    }
                } else {
                    sendResult(FlutterError(code: "NO_CONTROLLER", message: "PiP controller is not available", details: nil))
                }
            }

            // Start the first attempt after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard self != nil else {
                    sendResult(FlutterError(code: "DISPOSED", message: "View was disposed", details: nil))
                    return
                }
                tryStartPip()
            }
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "PiP requires iOS 14.0+", details: nil))
        }
    }
    
    /// Finds the AVPlayerLayer in the view hierarchy
    func findPlayerLayer() -> AVPlayerLayer? {
        // Get the player layer from the AVPlayerViewController's view
        if let playerView = playerViewController.view {
            return findPlayerLayerInView(playerView)
        }
        return nil
    }

    /// Recursively searches for AVPlayerLayer in view hierarchy
    private func findPlayerLayerInView(_ view: UIView) -> AVPlayerLayer? {
        // Check if this view's layer is an AVPlayerLayer
        if let playerLayer = view.layer as? AVPlayerLayer {
            return playerLayer
        }
        
        // Check sublayers
        if let sublayers = view.layer.sublayers {
            for sublayer in sublayers {
                if let playerLayer = sublayer as? AVPlayerLayer {
                    return playerLayer
                }
            }
        }
        
        // Recursively check subviews
        for subview in view.subviews {
            if let playerLayer = findPlayerLayerInView(subview) {
                return playerLayer
            }
        }
        
        return nil
    }
    

    func handleExitPictureInPicture(result: @escaping FlutterResult) {
        if #available(iOS 14.0, *) {
            // Call stopPictureInPicture() unconditionally — it is a safe no-op
            // when PiP is not active, and isPictureInPictureActive can desync
            // from visual state on iOS.

            // First check this view's pipController
            if let pipController = pipController {
                pipController.stopPictureInPicture()
                result(true)
                return
            }

            // Check other views for the same controller (e.g. navigated away from detail to list)
            if let controllerIdValue = controllerId {
                let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)

                for view in allViews {
                    if let otherPipController = view.pipController {
                        otherPipController.stopPictureInPicture()
                        result(true)
                        return
                    }
                }
            }

            // Fallback: check SharedPlayerManager for a stored PiP controller
            if let controllerIdValue = controllerId,
               let storedPipController = SharedPlayerManager.shared.getActivePipController(for: controllerIdValue) {
                storedPipController.stopPictureInPicture()
                result(true)
                return
            }

            // Final fallback: auto PiP managed by AVPlayerViewController — no custom
            // pipController exists. Apple does not expose a way to programmatically
            // stop AVPlayerViewController-managed PiP. Sync our state so the Dart
            // side knows PiP ended; the system PiP window persists until the user
            // closes it via its own controls.
            if isPipCurrentlyActive {
                isPipCurrentlyActive = false
                sendPipStopEvent()
                handlePipDidStop()
                result(true)
                return
            }

            result(false)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "PiP not supported on this iOS version", details: nil))
        }
    }

    func handleEnableAutomaticInlinePip(result: @escaping FlutterResult) {
        if #available(iOS 14.2, *) {
            // Check if video is loaded and playing
            guard let player = player, let currentItem = player.currentItem else {
                result(FlutterError(code: "NO_VIDEO", message: "No video loaded.", details: nil))
                return
            }

            guard currentItem.status == .readyToPlay else {
                result(FlutterError(code: "NOT_READY", message: "Video is not ready to play.", details: nil))
                return
            }

            // Check if PiP is supported on device
            guard AVPictureInPictureController.isPictureInPictureSupported() else {
                result(FlutterError(code: "NOT_SUPPORTED", message: "Picture-in-Picture is not supported on this device.", details: nil))
                return
            }


            // Enable auto background PiP on our custom controller
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
            }

            result(true)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "Automatic inline PiP requires iOS 14.2+", details: nil))
        }
    }

    func handleDisableAutomaticInlinePip(result: @escaping FlutterResult) {
        if #available(iOS 14.2, *) {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = false
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: false)
            }
            result(true)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "Automatic inline PiP requires iOS 14.2+", details: nil))
        }
    }

    /// Sets up periodic time observer to update Now Playing elapsed time
    func setupPeriodicTimeObserver() {
        // Remove existing observer if any
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        // Update Now Playing info every second (live streams don't need
        // sub-second elapsed-time display since there's no scrubbing).
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self = self, let player = self.player, let currentItem = player.currentItem else { return }

            // Update Now Playing info (cheap no-op for live streams since the
            // helper short-circuits when rate is unchanged; relevant calls for
            // play/pause/seek/skip already update directly).
            self.updateNowPlayingPlaybackTime()

            // Skip the position/duration/timeUpdate computation for live HLS —
            // there's no scrubbing UI on live and computing seekable ranges +
            // sending an event over the channel every second is pure overhead.
            if currentItem.duration.isIndefinite {
                return
            }

            // VOD path — live HLS already returned above.
            let currentTime = player.currentTime()
            let positionSeconds = CMTimeGetSeconds(currentTime)
            let durationSeconds = CMTimeGetSeconds(currentItem.duration)

            // Get buffered position
            var bufferedSeconds = 0.0
            let loadedRanges = currentItem.loadedTimeRanges
            if !loadedRanges.isEmpty {
                // Get the most recent buffered range
                let bufferedRange = loadedRanges.last!.timeRangeValue
                let bufferedEnd = CMTimeAdd(bufferedRange.start, bufferedRange.duration)
                bufferedSeconds = CMTimeGetSeconds(bufferedEnd)
            }

            // Check if currently buffering
            let isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate

            // Only send event if values are valid (not NaN or Infinity)
            if positionSeconds.isFinite && !positionSeconds.isNaN &&
               durationSeconds.isFinite && !durationSeconds.isNaN && durationSeconds > 0 {
                let position = Int(positionSeconds * 1000) // milliseconds
                let totalDuration = Int(durationSeconds * 1000) // milliseconds
                let bufferedPosition = Int(bufferedSeconds * 1000) // milliseconds

                self.sendEvent("timeUpdate", data: [
                    "position": position,
                    "duration": totalDuration,
                    "bufferedPosition": bufferedPosition,
                    "isBuffering": isBuffering
                ])
            }
        }
    }

    /// Determines if a URL is an HLS stream
    /// Checks for .m3u8 extension or common HLS patterns
    private func isHlsUrl(_ url: URL) -> Bool {
        let urlString = url.absoluteString.lowercased()

        // Check for .m3u8 extension (most reliable indicator)
        if urlString.contains(".m3u8") {
            return true
        }

        // Check for /hls/ as a path segment (not substring to avoid false positives like "english")
        if urlString.range(of: "/hls/", options: .regularExpression) != nil {
            return true
        }

        // Check for manifest in path
        if urlString.contains("manifest.m3u8") {
            return true
        }

        return false
    }

    // MARK: - Subtitle Track Handling

    func handleGetAvailableSubtitleTracks(result: @escaping FlutterResult) {
        guard let playerItem = player?.currentItem,
              let asset = playerItem.asset as? AVURLAsset else {
            result([])
            return
        }

        // Get all media selection options for legible characteristics (subtitles/captions)
        guard let mediaSelectionGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            result([])
            return
        }

        var tracks: [[String: Any]] = []

        // Get currently selected subtitle option
        let currentSelection = playerItem.currentMediaSelection.selectedMediaOption(in: mediaSelectionGroup)

        // Add each subtitle option
        for (index, option) in mediaSelectionGroup.options.enumerated() {
            let isSelected = option == currentSelection

            // Get language code (e.g., "en", "es", "fr")
            let languageCode = option.extendedLanguageTag ?? option.locale?.identifier ?? "unknown"

            // Get display name (e.g., "English", "Spanish", "French")
            var displayName = option.displayName

            // If display name is empty, try to get it from locale
            if displayName.isEmpty, let locale = option.locale {
                displayName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? languageCode
            }

            // If still empty, use language code
            if displayName.isEmpty {
                displayName = languageCode
            }

            let trackInfo: [String: Any] = [
                "index": index,
                "language": languageCode,
                "displayName": displayName,
                "isSelected": isSelected
            ]

            tracks.append(trackInfo)
        }

        result(tracks)
    }

    func handleSetMediaInfo(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let mediaInfo = arguments["mediaInfo"] as? [String: Any]
        else {
            result(FlutterError(code: "INVALID_ARGS", message: "Invalid media info arguments", details: nil))
            return
        }

        // Store locally
        currentMediaInfo = mediaInfo

        // Persist in SharedPlayerManager
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setMediaInfo(for: controllerIdValue, mediaInfo: mediaInfo)
        }

        // Update Now Playing info
        setupNowPlayingInfo(mediaInfo: mediaInfo)

        result(nil)
    }

    func handleSetSubtitleTrack(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let trackInfo = args["track"] as? [String: Any],
              let index = trackInfo["index"] as? Int else {
            result(FlutterError(code: "INVALID_TRACK", message: "Invalid subtitle track data", details: nil))
            return
        }

        guard let playerItem = player?.currentItem,
              let asset = playerItem.asset as? AVURLAsset else {
            result(FlutterError(code: "NO_PLAYER", message: "No player item available", details: nil))
            return
        }

        guard let mediaSelectionGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            result(FlutterError(code: "NO_SUBTITLES", message: "No subtitle tracks available", details: nil))
            return
        }

        // Index -1 means disable subtitles
        if index == -1 {
            playerItem.select(nil, in: mediaSelectionGroup)
            sendEvent("subtitleChange", data: [
                "index": -1,
                "language": "off",
                "displayName": "Off",
                "isSelected": false
            ])
            result(nil)
            return
        }

        // Validate index
        guard index >= 0 && index < mediaSelectionGroup.options.count else {
            result(FlutterError(code: "INVALID_INDEX", message: "Invalid subtitle track index", details: nil))
            return
        }

        // Select the subtitle option
        let option = mediaSelectionGroup.options[index]
        playerItem.select(option, in: mediaSelectionGroup)

        let languageCode = option.extendedLanguageTag ?? option.locale?.identifier ?? "unknown"
        var displayName = option.displayName

        if displayName.isEmpty, let locale = option.locale {
            displayName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? languageCode
        }

        if displayName.isEmpty {
            displayName = languageCode
        }


        sendEvent("subtitleChange", data: [
            "index": index,
            "language": languageCode,
            "displayName": displayName,
            "isSelected": true
        ])

        result(nil)
    }

    /// Returns the active key window across all connected scenes.
    /// Replaces the deprecated `UIApplication.shared.keyWindow`, which returns
    /// nil or the wrong window on multi-scene iPadOS. Prefers foreground-active
    /// scenes, falling back to any scene if none are active.
    static func activeKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow })
            ?? scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
    }
}
