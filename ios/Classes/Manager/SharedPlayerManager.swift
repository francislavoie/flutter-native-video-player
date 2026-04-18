import AVFoundation
import AVKit
import Flutter
import MediaPlayer

// MARK: - Shared Player Manager

/// Manages shared AVPlayer instances across multiple platform views
/// Keeps players alive even when platform views are disposed
/// Note: Each platform view gets its own AVPlayerViewController, but they share the same AVPlayer
class SharedPlayerManager: NSObject {
    static let shared = SharedPlayerManager()

    /// Serializes access to every mutable dictionary/set below.
    /// Recursive so a locked method can call another locked method
    /// (e.g. setAutomaticPiPEnabled → isManualPiPActive) without deadlocking.
    private let lock = NSRecursiveLock()

    private var players: [Int: AVPlayer] = [:]

    /// Whether any players are currently registered (used to decide audio session deactivation)
    var hasActivePlayers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !players.isEmpty
    }

    /// Shared AVPlayerViewController instances (persist across view disposal)
    /// Keeps view controllers alive so PiP delegate callbacks can fire even when platform views are disposed
    private var playerViewControllers: [Int: AVPlayerViewController] = [:]

    /// Global AirPlay route detector
    /// Used to monitor AirPlay availability across the entire app
    private var globalRouteDetector: AVRouteDetector?

    /// Track which controller currently has automatic PiP enabled
    /// Only one controller should have automatic PiP active at a time
    private var controllerWithAutomaticPiP: Int?

    /// Track which controllers have MANUAL PiP active
    /// This prevents automatic PiP from interfering with manual PiP
    private var controllersWithManualPiP: Set<Int> = []

    /// Active PiP controllers keyed by controller ID.
    /// Stored here so PiP can be exited even after the originating view is disposed.
    private var activePipControllers: [Int: AVPictureInPictureController] = [:]

    /// Track which view ID is the PRIMARY (most recently played) view for each controller
    /// This ensures we enable PiP on the correct view when multiple views exist (list + detail)
    private var primaryViewIdForController: [Int: Int64] = [:]

    /// Store references to ALL active VideoPlayerView instances
    /// Multiple platform views can exist for the same controller (list + detail screen)
    /// We need weak references to avoid retain cycles
    /// Key is a unique identifier (viewId), value is the view
    private var videoPlayerViews: [String: WeakVideoPlayerViewWrapper] = [:]

    /// Store PiP settings for each controller
    /// This ensures PiP settings persist across all views using the same controller
    private var pipSettings: [Int: PipSettings] = [:]

    /// Store available qualities for each controller
    /// This ensures qualities persist across view recreations
    private var qualitiesCache: [Int: [[String: Any]]] = [:]

    /// Store quality levels for each controller
    private var qualityLevelsCache: [Int: [VideoPlayer.QualityLevel]] = [:]

    /// Store media info for each controller
    /// This ensures media info persists across view recreations and during PiP transitions
    private var mediaInfoCache: [Int: [String: Any]] = [:]

    /// Controller-level event sinks (persistent, independent of platform views)
    /// These persist to send PiP and AirPlay events even when all views are disposed
    private var controllerEventSinks: [Int: FlutterEventSink] = [:]

    struct PipSettings {
        let allowsPictureInPicture: Bool
        let canStartPictureInPictureAutomatically: Bool
        let showNativeControls: Bool
    }

    private override init() {
        super.init()
    }

    private func configurePlayerForBackgroundPlayback(_ player: AVPlayer) {
        if #available(iOS 15.0, *) {
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
        // Start playing as soon as enough data is available for the first frame,
        // rather than waiting for a full buffer. This is set at creation time so
        // it takes effect before any content is loaded — setting it after loadUrl
        // means AVPlayer may have already started buffering with the default (true)
        // which delays time-to-first-frame for live streams.
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// Gets or creates a player for the given controller ID
    /// Returns a tuple (AVPlayer, Bool) where the Bool indicates if the player already existed (true) or was newly created (false)
    func getOrCreatePlayer(for controllerId: Int) -> (AVPlayer, Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let existingPlayer = players[controllerId] {
            return (existingPlayer, true)
        }

        let newPlayer = AVPlayer()
        configurePlayerForBackgroundPlayback(newPlayer)
        players[controllerId] = newPlayer
        return (newPlayer, false)
    }

    /// Gets or creates BOTH a player and view controller for the given controller ID
    /// Returns a tuple (AVPlayer, AVPlayerViewController, Bool) where the Bool indicates if they already existed
    /// This ensures the view controller persists across platform view disposal so PiP delegate callbacks continue to work
    func getOrCreatePlayerAndViewController(for controllerId: Int) -> (AVPlayer, AVPlayerViewController, Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let existingPlayer = players[controllerId],
           let existingViewController = playerViewControllers[controllerId] {
            return (existingPlayer, existingViewController, true)
        }

        // Create new player
        let newPlayer = AVPlayer()
        configurePlayerForBackgroundPlayback(newPlayer)
        players[controllerId] = newPlayer

        // Create new view controller
        let newViewController = AVPlayerViewController()
        newViewController.player = newPlayer
        playerViewControllers[controllerId] = newViewController

        return (newPlayer, newViewController, false)
    }

    /// Sets PiP settings for a controller
    /// This ensures the settings persist across all views using the same controller
    func setPipSettings(for controllerId: Int, allowsPictureInPicture: Bool, canStartPictureInPictureAutomatically: Bool, showNativeControls: Bool) {
        lock.lock()
        defer { lock.unlock() }
        pipSettings[controllerId] = PipSettings(
            allowsPictureInPicture: allowsPictureInPicture,
            canStartPictureInPictureAutomatically: canStartPictureInPictureAutomatically,
            showNativeControls: showNativeControls
        )
    }

    /// Gets PiP settings for a controller
    /// Returns nil if no settings have been stored for this controller
    func getPipSettings(for controllerId: Int) -> PipSettings? {
        lock.lock()
        defer { lock.unlock() }
        return pipSettings[controllerId]
    }

    /// Sets available qualities for a controller
    /// This ensures qualities persist across view recreations
    func setQualities(for controllerId: Int, qualities: [[String: Any]], qualityLevels: [VideoPlayer.QualityLevel]) {
        lock.lock()
        defer { lock.unlock() }
        qualitiesCache[controllerId] = qualities
        qualityLevelsCache[controllerId] = qualityLevels
    }

    /// Gets available qualities for a controller
    /// Returns nil if no qualities have been stored for this controller
    func getQualities(for controllerId: Int) -> [[String: Any]]? {
        lock.lock()
        defer { lock.unlock() }
        return qualitiesCache[controllerId]
    }

    /// Gets quality levels for a controller
    /// Returns nil if no quality levels have been stored for this controller
    func getQualityLevels(for controllerId: Int) -> [VideoPlayer.QualityLevel]? {
        lock.lock()
        defer { lock.unlock() }
        return qualityLevelsCache[controllerId]
    }

    /// Sets media info for a controller
    /// This ensures media info persists across view recreations and during PiP transitions
    func setMediaInfo(for controllerId: Int, mediaInfo: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        mediaInfoCache[controllerId] = mediaInfo
    }

    /// Gets media info for a controller
    /// Returns nil if no media info has been stored for this controller
    func getMediaInfo(for controllerId: Int) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return mediaInfoCache[controllerId]
    }

    // MARK: - Controller Event Channel Methods

    /// Registers a controller-level event sink for persistent events
    /// This sink receives PiP and AirPlay events independently of platform views
    func registerControllerEventSink(_ eventSink: @escaping FlutterEventSink, for controllerId: Int) {
        lock.lock()
        controllerEventSinks[controllerId] = eventSink
        lock.unlock()

        // Send initial controller state (reads globalRouteDetector, which
        // itself locks; call outside the lock we just released).
        sendInitialControllerState(for: controllerId, to: eventSink)
    }

    /// Unregisters a controller-level event sink
    func unregisterControllerEventSink(for controllerId: Int) {
        lock.lock()
        defer { lock.unlock() }
        controllerEventSinks.removeValue(forKey: controllerId)
    }

    /// Sends an event through the controller-level event channel
    func sendControllerEvent(_ eventName: String, data: [String: Any], for controllerId: Int) {
        lock.lock()
        let sink = controllerEventSinks[controllerId]
        lock.unlock()
        guard let eventSink = sink else { return }

        var event = data
        event["event"] = eventName

        DispatchQueue.main.async {
            eventSink(event)
        }
    }

    /// Sends initial controller state when event sink is registered
    private func sendInitialControllerState(for controllerId: Int, to eventSink: @escaping FlutterEventSink) {
        // Send initial PiP availability (always true on iOS for devices that support it)
        let pipAvailabilityEvent: [String: Any] = [
            "event": "pipAvailabilityChanged",
            "isAvailable": AVPictureInPictureController.isPictureInPictureSupported()
        ]
        DispatchQueue.main.async {
            eventSink(pipAvailabilityEvent)
        }

        // Send initial AirPlay availability from global route detector
        lock.lock()
        let detector = globalRouteDetector
        lock.unlock()
        if let detector = detector {
            let airplayAvailabilityEvent: [String: Any] = [
                "event": "airPlayAvailabilityChanged",
                "isAvailable": detector.isRouteDetectionEnabled && detector.multipleRoutesDetected
            ]
            DispatchQueue.main.async {
                eventSink(airplayAvailabilityEvent)
            }
        }

        // Note: Initial PiP state and AirPlay connection state will be sent
        // when views are created and report their current state
    }

    /// Stops and clears player from all views using this controller
    func stopAllViewsForController(_ controllerId: Int) {
        lock.lock()
        defer { lock.unlock() }

        guard let player = players[controllerId] else {
            return
        }

        // Pause and clear the player
        player.pause()
        player.replaceCurrentItem(with: nil)

        // Remove time observers and clear player reference from all views
        for (_, weakView) in videoPlayerViews {
            if let view = weakView.view, view.controllerId == controllerId {
                if let observer = view.timeObserver {
                    player.removeTimeObserver(observer)
                    view.timeObserver = nil
                }
                view.player = nil
            }
        }
    }

    /// Removes a player (called when explicitly disposed)
    func removePlayer(for controllerId: Int) {
        lock.lock()
        defer { lock.unlock() }

        // First stop all views using this player (recursive lock allows nested call)
        stopAllViewsForController(controllerId)

        // Remove player from manager
        players.removeValue(forKey: controllerId)

        // Remove and dispose view controller
        if let viewController = playerViewControllers.removeValue(forKey: controllerId) {
            viewController.player = nil
            viewController.delegate = nil
        }

        // Remove all views for this controller
        videoPlayerViews = videoPlayerViews.filter { $0.value.view?.controllerId != controllerId }

        // Clear primary view tracking
        primaryViewIdForController.removeValue(forKey: controllerId)

        // Remove PiP settings
        pipSettings.removeValue(forKey: controllerId)

        // Remove qualities cache
        qualitiesCache.removeValue(forKey: controllerId)
        qualityLevelsCache.removeValue(forKey: controllerId)

        // Remove media info cache
        mediaInfoCache.removeValue(forKey: controllerId)

        // If this was the controller with automatic PiP, clear it
        if controllerWithAutomaticPiP == controllerId {
            controllerWithAutomaticPiP = nil
        }

        // Clear manual PiP flag
        controllersWithManualPiP.remove(controllerId)

        // Clear active PiP controller reference
        if #available(iOS 14.0, *) {
            activePipControllers.removeValue(forKey: controllerId)
        }

        // Clear Now Playing info and remote commands as safety net.
        // The view's cleanupRemoteCommandOwnership() should handle this,
        // but races between view deinit and method channel disposal can
        // leave stale metadata on the lock screen.
        RemoteCommandManager.shared.removeAllTargets()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        deactivateAudioSessionIfIdle()
    }

    /// Clears all players (e.g., on logout)
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        // Dispose all view controllers
        for (_, viewController) in playerViewControllers {
            viewController.player = nil
            viewController.delegate = nil
        }
        playerViewControllers.removeAll()

        players.removeAll()
        videoPlayerViews.removeAll()
        primaryViewIdForController.removeAll()
        pipSettings.removeAll()
        qualitiesCache.removeAll()
        qualityLevelsCache.removeAll()
        mediaInfoCache.removeAll()
        controllerWithAutomaticPiP = nil
        controllersWithManualPiP.removeAll()
        if #available(iOS 14.0, *) {
            activePipControllers.removeAll()
        }

        deactivateAudioSessionIfIdle()
    }

    /// Releases `.playback` if no players remain. Holding the session active
    /// with no player keeps the iOS audio subsystem powered and blocks
    /// low-power sleep; `.notifyOthersOnDeactivation` lets backgrounded apps
    /// resume audio.
    private func deactivateAudioSessionIfIdle() {
        guard players.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    // MARK: - AirPlay Route Detection

    /// Starts global AirPlay route detection
    /// This monitors AirPlay device availability across the entire app
    @available(iOS 11.0, *)
    func startAirPlayRouteDetection() {
        lock.lock()
        defer { lock.unlock() }

        // Clean up any existing detector
        if let existingDetector = globalRouteDetector {
            existingDetector.removeObserver(self, forKeyPath: "multipleRoutesDetected")
            globalRouteDetector = nil
        }

        // Create and configure new route detector
        globalRouteDetector = AVRouteDetector()
        globalRouteDetector?.isRouteDetectionEnabled = true

        // Observe changes to multipleRoutesDetected
        globalRouteDetector?.addObserver(
            self,
            forKeyPath: "multipleRoutesDetected",
            options: [.new, .initial],
            context: nil
        )


        // Send initial availability state (sendAirPlayAvailabilityEvent takes
        // the recursive lock itself — safe to call from here).
        if let isAvailable = globalRouteDetector?.multipleRoutesDetected {
            sendAirPlayAvailabilityEvent(isAvailable: isAvailable)
        }
    }

    /// Stops global AirPlay route detection
    @available(iOS 11.0, *)
    func stopAirPlayRouteDetection() {
        lock.lock()
        defer { lock.unlock() }

        guard let detector = globalRouteDetector else {
            return
        }

        detector.removeObserver(self, forKeyPath: "multipleRoutesDetected")
        detector.isRouteDetectionEnabled = false
        globalRouteDetector = nil

    }

    /// Sends AirPlay availability event to Flutter through all registered views
    private func sendAirPlayAvailabilityEvent(isAvailable: Bool) {
        lock.lock()
        // Clean up nil/deallocated views first, then snapshot live views so
        // we don't call into Flutter while holding the lock.
        videoPlayerViews = videoPlayerViews.filter { $0.value.view != nil }
        let liveViews = videoPlayerViews.values.compactMap { $0.view }
        lock.unlock()

        for view in liveViews {
            view.sendEvent("airPlayAvailabilityChanged", data: ["isAvailable": isAvailable])
        }
    }

    /// KVO observer for route detector changes
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "multipleRoutesDetected" {
            if #available(iOS 11.0, *) {
                lock.lock()
                let isAvailable = globalRouteDetector?.multipleRoutesDetected
                lock.unlock()
                if let isAvailable = isAvailable {
                    sendAirPlayAvailabilityEvent(isAvailable: isAvailable)
                }
            }
        }
    }

    /// Register a VideoPlayerView instance
    /// Multiple views can be registered for the same controller (e.g., list + detail screen)
    func registerVideoPlayerView(_ view: VideoPlayerView, viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(viewId)"
        videoPlayerViews[key] = WeakVideoPlayerViewWrapper(view: view)
    }

    /// Unregister a VideoPlayerView when it's disposed
    func unregisterVideoPlayerView(viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(viewId)"
        videoPlayerViews.removeValue(forKey: key)
    }

    /// Find another active view for a given controller (excluding a specific viewId)
    /// Returns the view instance if found, nil otherwise
    func findAnotherViewForController(_ controllerId: Int, excluding excludedViewId: Int64) -> VideoPlayerView? {
        lock.lock()
        defer { lock.unlock() }
        // Clean up nil/deallocated views first
        videoPlayerViews = videoPlayerViews.filter { $0.value.view != nil }

        // Find another view with the same controller
        for (_, wrapper) in videoPlayerViews {
            if let view = wrapper.view,
               view.controllerId == controllerId,
               view.viewId != excludedViewId {
                return view
            }
        }

        return nil
    }

    /// Find all active views for a given controller
    /// Returns an array of view instances
    func findAllViewsForController(_ controllerId: Int) -> [VideoPlayerView] {
        lock.lock()
        defer { lock.unlock() }
        // Clean up nil/deallocated views first
        videoPlayerViews = videoPlayerViews.filter { $0.value.view != nil }

        var views: [VideoPlayerView] = []
        for (_, wrapper) in videoPlayerViews {
            if let view = wrapper.view, view.controllerId == controllerId {
                views.append(view)
            }
        }

        return views
    }

    /// Check if a controller is currently the active one for automatic PiP
    func isControllerActiveForAutoPiP(_ controllerId: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return controllerWithAutomaticPiP == controllerId
    }

    /// Mark that manual PiP is active for a controller
    func setManualPiPActive(_ controllerId: Int, active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if active {
            controllersWithManualPiP.insert(controllerId)
        } else {
            controllersWithManualPiP.remove(controllerId)
        }
    }

    /// Check if manual PiP is active for a controller
    func isManualPiPActive(_ controllerId: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return controllersWithManualPiP.contains(controllerId)
    }

    /// Store the active PiP controller for a given controller ID.
    /// This allows PiP to be exited even after the originating view is disposed.
    @available(iOS 14.0, *)
    func setActivePipController(_ pipController: AVPictureInPictureController, for controllerId: Int) {
        lock.lock()
        defer { lock.unlock() }
        activePipControllers[controllerId] = pipController
    }

    /// Clear the active PiP controller for a given controller ID.
    @available(iOS 14.0, *)
    func clearActivePipController(for controllerId: Int) {
        lock.lock()
        defer { lock.unlock() }
        activePipControllers.removeValue(forKey: controllerId)
    }

    /// Get the active PiP controller for a given controller ID, if any.
    @available(iOS 14.0, *)
    func getActivePipController(for controllerId: Int) -> AVPictureInPictureController? {
        lock.lock()
        defer { lock.unlock() }
        return activePipControllers[controllerId]
    }

    /// Check if ANY view for this controller currently has PiP active
    /// This checks the isPipCurrentlyActive flag on all views for the controller
    func isPipActiveForController(_ controllerId: Int) -> Bool {
        let allViews = findAllViewsForController(controllerId)
        for view in allViews {
            if view.isPipCurrentlyActive {
                return true
            }
        }
        return false
    }

    /// Set the primary (currently playing) view for a controller
    /// This should be called whenever play() is called on a view
    func setPrimaryView(_ viewId: Int64, for controllerId: Int) {
        lock.lock()
        defer { lock.unlock() }
        primaryViewIdForController[controllerId] = viewId
    }

    /// Check if a specific view is the primary view for a controller
    func isPrimaryView(_ viewId: Int64, for controllerId: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return primaryViewIdForController[controllerId] == viewId
    }

    /// Get the primary view ID for a controller (if any)
    func getPrimaryViewId(for controllerId: Int) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return primaryViewIdForController[controllerId]
    }
    
    /// Enable automatic PiP for a specific controller and disable for all others
    /// This ensures only one player can enter automatic PiP at a time
    /// IMPORTANT: Only enables on the MOST RECENT (primary) view for that controller
    @available(iOS 14.2, *)
    func setAutomaticPiPEnabled(for controllerId: Int, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }

        // Clean up nil/deallocated views first
        videoPlayerViews = videoPlayerViews.filter { $0.value.view != nil }

        // NOTE: We intentionally do NOT set canStartPictureInPictureAutomaticallyFromInline
        // on any AVPlayerViewController. AVPlayerViewController-managed auto PiP cannot be
        // programmatically stopped, causing a gray PiP window. Instead, we track which
        // controller/view should get background PiP and trigger it ourselves via a custom
        // AVPictureInPictureController when the app enters background.

        if enabled {
            // isManualPiPActive re-acquires the recursive lock — safe here.
            if isManualPiPActive(controllerId) {
                return
            }

            // Track which controller has background PiP enabled (only one at a time)
            controllerWithAutomaticPiP = controllerId

            // Ensure the primary view is set — fall back to any view if primary is disposed
            if let primaryViewId = primaryViewIdForController[controllerId] {
                let key = "\(primaryViewId)"
                if videoPlayerViews[key]?.view == nil {
                    // Primary view disposed — find a fallback
                    for (_, wrapper) in videoPlayerViews {
                        if let view = wrapper.view, view.controllerId == controllerId,
                           view.canStartPictureInPictureAutomatically {
                            primaryViewIdForController[controllerId] = view.viewId
                            break
                        }
                    }
                }
            }
        } else {
            if controllerWithAutomaticPiP == controllerId {
                controllerWithAutomaticPiP = nil
            }
        }
    }
}

// MARK: - Weak Wrapper

/// Wrapper to hold weak reference to VideoPlayerView
class WeakVideoPlayerViewWrapper {
    weak var view: VideoPlayerView?
    
    init(view: VideoPlayerView) {
        self.view = view
    }
}
