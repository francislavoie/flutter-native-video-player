import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer
import QuartzCore

// MARK: - Main Video Player View

@objc public class VideoPlayerView: NSObject, FlutterPlatformView, FlutterStreamHandler {
    var playerViewController: AVPlayerViewController
    var player: AVPlayer?
    private var methodChannel: FlutterMethodChannel
    private var channelName: String
    var eventSink: FlutterEventSink?
    var availableQualities: [[String: Any]] = []
    var qualityLevels: [VideoPlayer.QualityLevel] = []
    var controllerId: Int?
    var pipController: AVPictureInPictureController?
    var playWhenReadyObserver: NSKeyValueObservation?

    // Track if PiP is currently active (for both automatic and manual PiP)
    var isPipCurrentlyActive: Bool = false

    // Track if we've already registered remote command handlers
    // This prevents re-registering and clearing targets unnecessarily
    var hasRegisteredRemoteCommands: Bool = false

    /// Force re-registration of remote commands
    /// Call this when you know the targets might have been removed externally
    func forceReregisterRemoteCommands() {

        // Only force re-registration if we don't already own the commands
        // or if the commands aren't properly set up
        let commandCenter = MPRemoteCommandCenter.shared()
        let hasTargets = commandCenter.playCommand.isEnabled && commandCenter.pauseCommand.isEnabled

        if RemoteCommandManager.shared.isOwner(viewId) && hasTargets {
            // Just restore Now Playing info without touching remote commands
            if let mediaInfo = currentMediaInfo {
                setupNowPlayingInfo(mediaInfo: mediaInfo)
            }
            return
        }

        hasRegisteredRemoteCommands = false
        if let mediaInfo = currentMediaInfo {
            setupNowPlayingInfo(mediaInfo: mediaInfo)
        }
    }

    // Store the platform view ID for registration
    var viewId: Int64 = 0
    
    // Store whether automatic PiP was requested in creation params
    var canStartPictureInPictureAutomatically: Bool = true

    // Separate player view controller for fullscreen (prevents removing embedded view)
    var fullscreenPlayerViewController: AVPlayerViewController?

    // When true, this platform view is the Dart fullscreen host and uses its own AVPlayerViewController
    // (same AVPlayer) so the inline view never loses its shared view. Cleared in deinit.
    var isDartFullscreenView: Bool = false

    // Master playlist URL for reloading after audio-only playback
    var masterPlaylistUrl: URL?

    // Store media info for Now Playing
    var currentMediaInfo: [String: Any]?
    var timeObserver: Any?

    // Cached artwork to avoid race conditions — the async artwork load
    // reads the CURRENT nowPlayingInfo on completion instead of capturing
    // a stale snapshot, and this cache lets subsequent setupNowPlayingInfo
    // calls include artwork immediately if the URL hasn't changed.
    var cachedArtwork: MPMediaItemArtwork?
    var cachedArtworkUrl: String?

    // Track if this is a shared player (to avoid sending duplicate initialization events)
    var isSharedPlayer: Bool = false

    // Store desired playback speed
    var desiredPlaybackSpeed: Float = 1.0

    // Store HDR setting
    // Store looping setting
    var enableLooping: Bool = false

    // DRM handler for protected content
    var drmHandler: VideoPlayerDrmHandler?

    // Re-entrancy guard for seekToLiveEdgeAndPlay to prevent overlapping seeks
    var isRecoveringFromStall: Bool = false

    // Track whether player-level KVO observers have been added
    // Prevents duplicate observers when addObservers is called multiple times (e.g., on re-load)
    var hasPlayerObservers: Bool = false

    // Latest AVPlayerItemErrorLogEvent captured by the error-log notification.
    // Only statusCode is consumed on the Dart side today (to distinguish
    // 4xx "session gone" from 5xx "transient"). Cleared when a new item
    // reaches .readyToPlay so stale codes don't leak into a fresh session.
    var lastErrorStatusCode: Int = 0

    // Set after an "error" event is emitted for the current item; cleared on
    // the next .readyToPlay. Prevents AVFoundation's duplicate error signal
    // (item.status = .failed AND AVPlayerItemFailedToPlayToEndTime fire for
    // the same underlying failure) from double-billing Dart's recovery.
    var errorEmittedForCurrentItem: Bool = false

    // True between handlePause and the next play/load. Lets the .paused KVO
    // branch distinguish a deliberate user pause from a silent buffer stall
    // (where buffer state alone would misclassify a user pause near the live
    // edge, since isPlaybackLikelyToKeepUp can be false with a tight buffer).
    var userRequestedPause: Bool = false

    // Track whether playback was active before an audio session interruption
    // so we can decide whether to resume after the interruption ends.
    var wasPlayingBeforeInterruption: Bool = false

    public init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        self.viewId = viewId
        channelName = "native_video_player_\(viewId)"
        methodChannel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: messenger
        )

        // Extract controller ID from args to get shared player and view controller
        let argsDict = args as? [String: Any]
        let isDartFullscreen = argsDict?["isDartFullscreen"] as? Bool ?? false

        if let args = argsDict,
           let controllerIdValue = args["controllerId"] as? Int {
            controllerId = controllerIdValue

            // Get or create shared player AND view controller
            // This ensures the view controller persists across platform view disposal
            // so PiP delegate callbacks continue to work even when navigating away
            let (sharedPlayer, sharedViewController, alreadyExisted) =
                SharedPlayerManager.shared.getOrCreatePlayerAndViewController(for: controllerIdValue)

            player = sharedPlayer
            isSharedPlayer = alreadyExisted

            if isDartFullscreen {
                // Dart fullscreen host: use a dedicated AVPlayerViewController (same player) so the inline
                // view never loses its shared view when this platform view is created or disposed.
                let dedicatedVC = AVPlayerViewController()
                dedicatedVC.player = sharedPlayer
                playerViewController = dedicatedVC
                isDartFullscreenView = true
            } else {
                if alreadyExisted {
                    // Second or later platform view for this controller (e.g. detail screen).
                    // Use a dedicated AVPlayerViewController with the shared player so this
                    // view has its own layer; the shared VC stays in SharedPlayerManager for PiP.
                    // This avoids black screen when navigating list↔detail (one UIView per slot).
                    let displayVC = AVPlayerViewController()
                    displayVC.player = sharedPlayer
                    playerViewController = displayVC
                } else {
                    playerViewController = sharedViewController
                }
            }
        } else {
            // Fallback: create new instances if no controller ID provided.
            // Match SharedPlayerManager.configurePlayerForBackgroundPlayback —
            // non-shared players are still live HLS and need the same flags.
            playerViewController = AVPlayerViewController()
            let newPlayer = AVPlayer()
            if #available(iOS 15.0, *) {
                newPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            }
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            player = newPlayer
            playerViewController.player = player
        }

        super.init()

        // Configure playback controls
        let showControls = (args as? [String: Any])?["showNativeControls"] as? Bool ?? true
        playerViewController.showsPlaybackControls = showControls
        playerViewController.delegate = self
        playerViewController.view.backgroundColor = .black

        // Disable automatic Now Playing updates - we'll handle it manually
        playerViewController.updatesNowPlayingInfoCenter = false

        // Disable Live Text analysis to prevent KVO crashes from Apple's
        // internal AVVideoFrameVisualAnalyzer during player item replacement
        if #available(iOS 16.0, *) {
            playerViewController.allowsVideoFrameAnalysis = false
        }

        // Extract configuration from Flutter args
        if let args = args as? [String: Any] {
            // PiP configuration from args
            let argsAllowsPiP = args["allowsPictureInPicture"] as? Bool ?? true
            let argsCanStartAutomatically = args["canStartPictureInPictureAutomatically"] as? Bool ?? true
            let argsShowNativeControls = args["showNativeControls"] as? Bool ?? true

            // Looping configuration from args
            enableLooping = args["enableLooping"] as? Bool ?? false

            // For shared players, try to get PiP settings from SharedPlayerManager
            // This ensures PiP settings persist across all views using the same controller
            // Keep AVPlayerViewController PiP disabled — all PiP goes through
            // our custom AVPictureInPictureController so we can stop it programmatically.
            playerViewController.allowsPictureInPicturePlayback = false

            if let controllerIdValue = controllerId {
                if let sharedSettings = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue) {
                    self.canStartPictureInPictureAutomatically = sharedSettings.canStartPictureInPictureAutomatically
                } else {
                    self.canStartPictureInPictureAutomatically = argsCanStartAutomatically
                    SharedPlayerManager.shared.setPipSettings(
                        for: controllerIdValue,
                        allowsPictureInPicture: argsAllowsPiP,
                        canStartPictureInPictureAutomatically: argsCanStartAutomatically,
                        showNativeControls: argsShowNativeControls
                    )
                }
            } else {
                self.canStartPictureInPictureAutomatically = argsCanStartAutomatically
            }

            if #available(iOS 14.2, *) {
                // Start with automatic PiP DISABLED
                // It will be enabled when this specific player starts playing (if allowed)
                // This prevents conflicts when multiple players exist
                playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
            }

            // Store media info if provided during initialization
            // This ensures we have the correct media info even for shared players
            if let mediaInfo = args["mediaInfo"] as? [String: Any] {
                currentMediaInfo = mediaInfo

                // Also store in SharedPlayerManager to persist across view recreations
                if let controllerIdValue = controllerId {
                    SharedPlayerManager.shared.setMediaInfo(for: controllerIdValue, mediaInfo: mediaInfo)
                }
            }
        }
        
        // Register this view with the SharedPlayerManager
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.registerVideoPlayerView(self, viewId: viewId)

            // Setup controller-level event channel (if not already set up)
            // This enables persistent event delivery for PiP and AirPlay
            NativeVideoPlayerPlugin.setupControllerEventChannel(for: controllerIdValue)

            // If this controller is currently the one with automatic PiP enabled OR if the player is playing,
            // this new view should become the primary view and get automatic PiP
            // BUT ONLY if manual PiP is not active
            if #available(iOS 14.2, *) {
                let isActiveForAutoPiP = SharedPlayerManager.shared.isControllerActiveForAutoPiP(controllerIdValue)
                let isPlaying = player?.rate ?? 0 > 0

                if isActiveForAutoPiP || isPlaying {
                    if canStartPictureInPictureAutomatically {
                        // Check if manual PiP is active - if so, skip re-enabling automatic PiP
                        if !SharedPlayerManager.shared.isManualPiPActive(controllerIdValue) {
                            // Set this new view as the primary view
                            SharedPlayerManager.shared.setPrimaryView(viewId, for: controllerIdValue)
                            // Re-apply automatic PiP settings to enable it on this new view
                            SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                        }
                    }
                }
            }
        }

        // Set up method call handler
        methodChannel.setMethodCallHandler({ [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard let self = self else {
                result(FlutterError(code: "DISPOSED", message: "VideoPlayerView was disposed", details: nil))
                return
            }
            self.handleMethodCall(call: call, result: result)
        })
        
        // Set up event channel
        let eventChannel = FlutterEventChannel(
            name: "native_video_player_\(viewId)",
            binaryMessenger: messenger
        )
        eventChannel.setStreamHandler(self)

        // Set up observers for shared players if there's already a loaded video
        // The initial state event will be sent when onListen is called
        if isSharedPlayer, let currentItem = player?.currentItem {
            addObservers(to: currentItem)
            // Also set up periodic time observer for this new view
            setupPeriodicTimeObserver()
        }

        // Observe app entering foreground to restore Now Playing info
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        // Observe audio session interruptions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        // iOS rarely restarts the media services subsystem (Apple QA1749).
        // When it does, every AVPlayer / AVAudioSession is orphaned and
        // playback silently breaks. Subscribe so we can surface the event
        // to Dart and trigger a hard refresh of the controller.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesWereReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )

        // AVRouteDetector is opt-in via the `startAirPlayDetection` method
        // channel (enables the shared detector in SharedPlayerManager). Apple
        // warns route detection "significantly increases power consumption",
        // so the per-view detector is no longer created eagerly.
    }

    /// Per Apple QA1749: when the media server resets, every AVPlayer and
    /// AVAudioSession is orphaned and silently broken. Surface as an error
    /// event so the host can drop the player and recreate from scratch.
    @objc func handleMediaServicesWereReset(notification: Notification) {
        player?.pause()

        let event: [String: Any] = [
            "code": "mediaServicesWereReset",
            "message": "Media services were reset. Refresh to resume playback.",
        ]
        sendEvent("error", data: event)
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.sendControllerEvent(
                "error",
                data: event,
                for: controllerIdValue
            )
        }
    }

    public func view() -> UIView {
        return playerViewController.view
    }

    // MARK: - Audio Session Management

    /// Prepares and activates the audio session for video playback
    /// This MUST be called before starting playback to ensure audio continues when screen locks
    func prepareAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            NSLog("[VideoPlayer] Audio session error: \(error.localizedDescription)")
        }
    }

    public func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "load":
            handleLoad(call: call, result: result)
        case "play":
            handlePlay(result: result)
        case "pause":
            handlePause(result: result)
        case "seekTo":
            handleSeekTo(call: call, result: result)
        case "setVolume":
            handleSetVolume(call: call, result: result)
        case "setSpeed":
            handleSetSpeed(call: call, result: result)
        case "setLooping":
            handleSetLooping(call: call, result: result)
        case "setQuality":
            handleSetQuality(call: call, result: result)
        case "getAvailableQualities":
            // First check if we have qualities in this view instance
            if !availableQualities.isEmpty {
                result(availableQualities)
            } else if let controllerIdValue = controllerId,
                      let cachedQualities = SharedPlayerManager.shared.getQualities(for: controllerIdValue) {
                // If view instance is empty but cache has qualities, restore them
                availableQualities = cachedQualities
                if let cachedQualityLevels = SharedPlayerManager.shared.getQualityLevels(for: controllerIdValue) {
                    qualityLevels = cachedQualityLevels
                }
                result(cachedQualities)
            } else {
                result(availableQualities)
            }
        case "getAvailableSubtitleTracks":
            handleGetAvailableSubtitleTracks(result: result)
        case "setSubtitleTrack":
            handleSetSubtitleTrack(call: call, result: result)
        case "enterFullScreen":
            handleEnterFullScreen(result: result)
        case "exitFullScreen":
            handleExitFullScreen(result: result)
        case "isPictureInPictureAvailable":
            handleIsPictureInPictureAvailable(result: result)
        case "enterPictureInPicture":
            handleEnterPictureInPicture(result: result)
        case "exitPictureInPicture":
            handleExitPictureInPicture(result: result)
        case "enableAutomaticInlinePip":
            handleEnableAutomaticInlinePip(result: result)
        case "disableAutomaticInlinePip":
            handleDisableAutomaticInlinePip(result: result)
        case "setShowNativeControls":
            handleSetShowNativeControls(call: call, result: result)
        case "setMediaInfo":
            handleSetMediaInfo(call: call, result: result)
        case "ensureSurfaceConnected":
            // No-op on iOS; each platform view uses its own AVPlayerViewController when shared.
            result(nil)
        case "isAirPlayAvailable":
            handleIsAirPlayAvailable(result: result)
        case "showAirPlayPicker":
            handleShowAirPlayPicker(result: result)
        case "disconnectAirPlay":
            handleDisconnectAirPlay(result: result)
        case "startAirPlayDetection":
            handleStartAirPlayDetection(result: result)
        case "stopAirPlayDetection":
            handleStopAirPlayDetection(result: result)
        case "configureForLivePlayback":
            handleConfigureForLivePlayback(call: call, result: result)
        case "getLatencyToLive":
            handleGetLatencyToLive(result: result)
        case "seekToLiveEdge":
            handleSeekToLiveEdge(result: result)
        case "dispose":
            handleDispose(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Creates the custom AVPictureInPictureController eagerly so it's warmed up
    /// for background PiP. Freshly created controllers need time before
    /// startPictureInPicture() works reliably.
    @available(iOS 14.0, *)
    func ensurePipController() {
        guard pipController == nil else { return }
        if let playerLayer = findPlayerLayer() {
            pipController = try? AVPictureInPictureController(playerLayer: playerLayer)
            pipController?.delegate = self
            // Enable auto background PiP on our controller (declarative).
            // Since we own the controller, stopPictureInPicture() always works.
            if #available(iOS 14.2, *), canStartPictureInPictureAutomatically {
                pipController?.canStartPictureInPictureAutomaticallyFromInline = true
            }
            if let ctrl = pipController, let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setActivePipController(ctrl, for: controllerIdValue)
            }
        }
    }

    public func sendEvent(_ name: String, data: [String: Any]? = nil) {
        var event: [String: Any] = ["event": name]
        if let data = data {
            event.merge(data) { (_, new) in
                new
            }
        }
        DispatchQueue.main.async {
            self.eventSink?(event)
        }
    }

    /// Cleans up remote command ownership, attempting to transfer to another view if possible
    /// This is called from both deinit and handleDispose to avoid duplication
    func cleanupRemoteCommandOwnership(excludingControllerId: Int? = nil) {
        // Only proceed if this view owns the remote commands
        guard RemoteCommandManager.shared.isOwner(viewId) else {
            return
        }


        // Try to transfer ownership before clearing process-global controls.
        var ownershipTransferred = false
        if let alternativeView = SharedPlayerManager.shared.findRemoteCommandReplacement(
            preferredControllerId: controllerId,
            excluding: viewId,
            excludingControllerId: excludingControllerId
        ) {

            // Transfer ownership by setting up Now Playing info on the alternative view
            var mediaInfo = alternativeView.currentMediaInfo

            // Fallback: Try to get media info from SharedPlayerManager
            if mediaInfo == nil, let replacementControllerId = alternativeView.controllerId {
                mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: replacementControllerId)
                if mediaInfo != nil {
                    alternativeView.currentMediaInfo = mediaInfo
                }
            }

            alternativeView.setupNowPlayingInfo(mediaInfo: mediaInfo ?? [:])
            ownershipTransferred = true
        }

        // CRITICAL: If no transfer was possible BUT PiP is active, DO NOT clear Now Playing info
        // PiP needs the media controls to work, so we must preserve them
        if !ownershipTransferred {
            let isPipActiveForController = controllerId.flatMap { SharedPlayerManager.shared.isPipActiveForController($0) } ?? false

            if isPipCurrentlyActive || isPipActiveForController {
                // Just clear the ownership flag, but keep the Now Playing info and remote commands active
                RemoteCommandManager.shared.clearOwner(viewId)
            } else {
                RemoteCommandManager.shared.clearOwner(viewId)
                RemoteCommandManager.shared.removeAllTargets()
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
        }
    }

    /// Emits all current player states to ensure UI is in sync.
    /// This is useful after events like exiting PiP where the UI needs to refresh.
    public func emitCurrentState() {
        emitPlaybackState()
        emitPipState()
    }

    /// Emits just the time/playback state — no PiP event.
    /// Used after a pipStart/pipStop has already been emitted inline.
    public func emitPlaybackState() {
        guard let player = player, let currentItem = player.currentItem else {
            return
        }


        // Emit current time and duration
        let currentTimeSeconds = CMTimeGetSeconds(player.currentTime())
        let durationSeconds = CMTimeGetSeconds(currentItem.duration)

        if !currentTimeSeconds.isNaN && !durationSeconds.isNaN && durationSeconds > 0 {
            let duration = Int(durationSeconds * 1000)
            let position = Int(currentTimeSeconds * 1000)

            // Get buffered position
            var bufferedSeconds = 0.0
            let timeRanges = currentItem.loadedTimeRanges
            if !timeRanges.isEmpty {
                let bufferedRange = timeRanges.last!.timeRangeValue
                let bufferedEnd = CMTimeAdd(bufferedRange.start, bufferedRange.duration)
                bufferedSeconds = CMTimeGetSeconds(bufferedEnd)
            }
            let bufferedPosition = Int(bufferedSeconds * 1000)

            sendEvent("timeUpdate", data: [
                "position": position,
                "duration": duration,
                "bufferedPosition": bufferedPosition,
                "isBuffering": player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            ])
        }

        // Emit current playback state
        switch player.timeControlStatus {
        case .playing:
            sendEvent("play")
        case .paused:
            sendEvent("pause")
        case .waitingToPlayAtSpecifiedRate:
            sendEvent("buffering")
        @unknown default:
            break
        }
    }

    /// Emits the current PiP state (pipStart or pipStop).
    public func emitPipState() {
        let isPipActive = isPipCurrentlyActive ||
                          (controllerId.flatMap { SharedPlayerManager.shared.isPipActiveForController($0) } ?? false)

        if isPipActive {
            sendEvent("pipStart", data: ["isPictureInPicture": true])
        } else {
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        }
    }

    // MARK: - FlutterStreamHandler
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events

        // Send initial state event when listener is attached
        if isSharedPlayer {
            // For shared players, only send current playback state and position
            if let player = player, let currentItem = player.currentItem {
                let currentTimeSeconds = CMTimeGetSeconds(player.currentTime())
                let durationSeconds = CMTimeGetSeconds(currentItem.duration)

                // Check for NaN or invalid times
                if !currentTimeSeconds.isNaN && !durationSeconds.isNaN {
                    let duration = Int(durationSeconds * 1000)
                    let position = Int(currentTimeSeconds * 1000)
                    sendEvent("timeUpdate", data: ["position": position, "duration": duration])
                }

                // Send current playback state
                switch player.timeControlStatus {
                case .playing:
                    sendEvent("play")
                case .paused:
                    sendEvent("pause")
                case .waitingToPlayAtSpecifiedRate:
                    sendEvent("buffering")
                @unknown default:
                    break
                }
            }

        } else {
            // For new players, send isInitialized event
            sendEvent("isInitialized")
        }

        // Initial AirPlay availability is delivered by SharedPlayerManager's
        // shared route detector — no per-view fan-out needed.

        // Send initial AirPlay connection state
        // Check at system level (audio route) rather than just this player's state
        // This ensures we detect if ANY player in the app is using AirPlay
        let deviceName = getAirPlayDeviceName()
        let isSystemAirPlayActive = deviceName != nil

        if let player = player {
            // Check if THIS specific player is using AirPlay
            let isPlayerAirPlayActive = player.isExternalPlaybackActive

            // We're connected if either:
            // 1. This player is actively using AirPlay, OR
            // 2. AirPlay device is detected in audio route (another player might be using it)
            let isConnected = isPlayerAirPlayActive || isSystemAirPlayActive

            if isConnected {

                var eventData: [String: Any] = ["isConnected": true, "isConnecting": false]
                if let deviceName = deviceName {
                    eventData["deviceName"] = deviceName
                }
                sendEvent("airPlayConnectionChanged", data: eventData)

                // If device name is not available yet, start retry sequence
                if deviceName == nil {
                    retryGetAirPlayDeviceName(attempt: 1, maxAttempts: 4)
                }
            } else {
                // Not connected at system or player level
                sendEvent("airPlayConnectionChanged", data: ["isConnected": false, "isConnecting": false])
            }
        }

        // Send initial PiP state
        // Check if PiP is currently active on this view or any view for the same controller
        let isPipActive = isPipCurrentlyActive ||
                          (controllerId.flatMap { SharedPlayerManager.shared.isPipActiveForController($0) } ?? false)

        if isPipActive {
            sendEvent("pipStart", data: ["isPictureInPicture": true])
        } else {
            // Send pipStop to ensure Flutter knows PiP is not active
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        }

        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    deinit {
        playWhenReadyObserver?.invalidate()
        playWhenReadyObserver = nil

        // Use the isPipCurrentlyActive flag to check if PiP is active
        let isPipActiveNow = isPipCurrentlyActive

        // ALWAYS emit PiP state on disposal to ensure Flutter side is synchronized
        // This is important for state management even if PiP is not active
        // Always send pipStop event - either from this view or an alternative
        if eventSink != nil {
            // This view still has a listener, send from here
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        } else if let controllerIdValue = controllerId,
                  let alternativeView = SharedPlayerManager.shared.findAnotherViewForController(controllerIdValue, excluding: viewId),
                  alternativeView.eventSink != nil {
            // Send from alternative view if it exists and has a listener
            alternativeView.sendEvent("pipStop", data: ["isPictureInPicture": false])
        }

        // Try to stop PiP gracefully if it was active
        if isPipActiveNow {
            if #available(iOS 14.0, *) {
                if let pipCtrl = pipController, pipCtrl.isPictureInPictureActive {
                    pipCtrl.stopPictureInPicture()
                }
            }
        }

        // Clean up remote command ownership (transfer to another view if possible)
        cleanupRemoteCommandOwnership()

        // Handle automatic PiP transfer for shared players
        // If this was the primary view (the one with automatic PiP enabled) OR if the player is playing,
        // we need to transfer automatic PiP to another view using the same controller
        if #available(iOS 14.2, *), let controllerIdValue = controllerId {
            let wasPrimaryView = SharedPlayerManager.shared.isPrimaryView(viewId, for: controllerIdValue)
            let wasAutoEnabled = SharedPlayerManager.shared.isControllerActiveForAutoPiP(controllerIdValue)
            let isPlaying = player?.rate ?? 0 > 0

            // Transfer automatic PiP if:
            // 1. This was the primary view AND auto PiP was enabled, OR
            // 2. The player is currently playing (should maintain auto PiP capability)
            if (wasPrimaryView && wasAutoEnabled) || isPlaying {
                // Unregister this view first so it won't be found
                SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)

                // Re-enable automatic PiP - this will find and enable a different view
                // for the same controller (if any exists)
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
            } else {
                // Normal unregister for non-primary views
                SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)
            }
        } else {
            // Normal unregister for non-shared players
            SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)
        }

        // Remove periodic time observer
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        // Only remove observers, don't dispose the player if it's shared
        // The shared player will be kept alive for reuse
        if let item = player?.currentItem {
            removeItemObservers(from: item)
        }

        // Only remove player-level observers if they were added
        if hasPlayerObservers {
            player?.removeObserver(self, forKeyPath: "timeControlStatus")
            player?.removeObserver(self, forKeyPath: "externalPlaybackActive")
            hasPlayerObservers = false
        }

        NotificationCenter.default.removeObserver(self)
        methodChannel.setMethodCallHandler(nil)

        // Clean up DRM handler
        drmHandler?.cleanup()
        drmHandler = nil

        // Clear current media info from this view
        // BUT do NOT clear from SharedPlayerManager if PiP is active
        // This ensures media controls survive view disposal during PiP
        currentMediaInfo = nil
        if !isPipActiveNow {
            // Only clear from SharedPlayerManager if PiP is NOT active
            // and this is the last view for the controller
            if let controllerIdValue = controllerId {
                let otherViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
                if otherViews.count <= 1 {
                    SharedPlayerManager.shared.setMediaInfo(for: controllerIdValue, mediaInfo: [:])
                }
            }
        }

        // Emit current state to all remaining views for this controller
        // This ensures other views stay in sync when one view is disposed
        if let controllerIdValue = controllerId {
            let remainingViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            if !remainingViews.isEmpty {
                for view in remainingViews {
                    // Skip the view being disposed (just in case it's still in the list)
                    if view.viewId != viewId {
                        view.emitCurrentState()
                    }
                }
            }
        }

        // For Dart fullscreen platform view, release the dedicated VC's player so it tears down.
        // The shared player and shared VC (inline view) are left untouched.
        if isDartFullscreenView {
            playerViewController.player = nil
        }

        // CRITICAL: For shared controllers, player and playerViewController are NOT disposed here
        // They're managed by SharedPlayerManager and persist across platform view disposal
        // This ensures PiP delegate callbacks continue to work when navigating between screens
        // Resources will be disposed when controller.dispose() is called from Dart
    }

    // MARK: - App Lifecycle Handling

    @objc func handleAppWillEnterForeground() {

        // Only reactivate the audio session if this player is actively
        // producing output. Apple's guidance: playback apps should NOT
        // blindly reactivate on foreground — doing so steals audio focus
        // from other apps (music, podcasts) even when nothing is playing.
        guard let player = player,
              player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        else { return }

        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("[VideoPlayer] Audio session error: \(error.localizedDescription)")
        }

        // Check if this view owns the remote commands
        guard RemoteCommandManager.shared.isOwner(viewId) else {
            return
        }

        // Check if we have media info to restore
        var mediaInfo = currentMediaInfo

        // Fallback: Try to retrieve from SharedPlayerManager if not available locally
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                currentMediaInfo = mediaInfo // Update local copy
            }
        }

        guard let mediaInfo = mediaInfo else {
            return
        }

        // Delay slightly to ensure audio session is fully active
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            // Restore Now Playing info
            self.setupNowPlayingInfo(mediaInfo: mediaInfo)

            // Also update the playback time to ensure controls show correct position
            self.updateNowPlayingPlaybackTime()

            // Seek to live edge for live streams — the player drifts behind
            // while backgrounded. Skip during PiP (already playing live),
            // audio-only (seek interrupts audio), and user-paused.
            let isAudioOnly: Bool = {
                guard let masterUrl = self.masterPlaylistUrl,
                      let currentUrl = (self.player?.currentItem?.asset as? AVURLAsset)?.url else { return false }
                return currentUrl != masterUrl
            }()
            if !self.isPipCurrentlyActive, !isAudioOnly,
               let player = self.player,
               (player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate),
               let item = player.currentItem, item.duration == .indefinite {
                self.seekToLiveEdgeAndPlay()
            }
        }
    }

    /// Called when audio session is interrupted (e.g., phone call, other app's audio)
    @objc func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }


        switch type {
        case .began:
            // Track whether we were playing so we can resume correctly after
            // the interruption ends (the system may not always set shouldResume).
            wasPlayingBeforeInterruption = (player?.rate ?? 0) > 0
        case .ended:
            // Check if we should resume playback
            var shouldResume = false
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    shouldResume = true
                }
            }

            // Reactivate audio session
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                NSLog("[VideoPlayer] Audio session error: \(error.localizedDescription)")
            }

            // Restore Now Playing info and resume playback if needed
            if RemoteCommandManager.shared.isOwner(viewId) {
                var mediaInfo = currentMediaInfo
                if mediaInfo == nil, let controllerIdValue = controllerId {
                    mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
                }

                if let mediaInfo = mediaInfo {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self = self else { return }
                        self.setupNowPlayingInfo(mediaInfo: mediaInfo)
                        self.updateNowPlayingPlaybackTime()

                        // Resume if the system recommends it, if we were
                        // playing when the interruption started, or if PiP
                        // is active (user intends continuous playback).
                        if shouldResume || self.wasPlayingBeforeInterruption || self.isPipCurrentlyActive {
                            if self.isPipCurrentlyActive {
                                // During PiP, just resume — brief interruptions
                                // (notification sounds) don't need a seek.
                                self.player?.play()
                            } else {
                                // Use seekToLiveEdgeAndPlay for live streams so the
                                // player snaps back to the live edge instead of
                                // resuming at a stale position behind the DVR window.
                                self.seekToLiveEdgeAndPlay()
                            }
                        }
                    }
                }
            }

        @unknown default:
            break
        }
    }
}

