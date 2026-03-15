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

    private let lock = NSLock()

    private var players: [Int: AVPlayer] = [:]

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
        pipSettings[controllerId] = PipSettings(
            allowsPictureInPicture: allowsPictureInPicture,
            canStartPictureInPictureAutomatically: canStartPictureInPictureAutomatically,
            showNativeControls: showNativeControls
        )
    }

    /// Gets PiP settings for a controller
    /// Returns nil if no settings have been stored for this controller
    func getPipSettings(for controllerId: Int) -> PipSettings? {
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
        controllerEventSinks[controllerId] = eventSink

        // Send initial controller state
        sendInitialControllerState(for: controllerId, to: eventSink)
    }

    /// Unregisters a controller-level event sink
    func unregisterControllerEventSink(for controllerId: Int) {
        controllerEventSinks.removeValue(forKey: controllerId)
    }

    /// Sends an event through the controller-level event channel
    func sendControllerEvent(_ eventName: String, data: [String: Any], for controllerId: Int) {
        guard let eventSink = controllerEventSinks[controllerId] else {
            // No event sink registered - this is normal during initialization or after disposal
            return
        }

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
        if let detector = globalRouteDetector {
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

        guard let player = players[controllerId] else {
            return
        }

        // Pause and clear the player
        player.pause()
        player.replaceCurrentItem(with: nil)

        // Remove time observers and clear player reference from all views
        var clearedViewCount = 0
        for (_, weakView) in videoPlayerViews {
            if let view = weakView.view, view.controllerId == controllerId {
                if let observer = view.timeObserver {
                    player.removeTimeObserver(observer)
                    view.timeObserver = nil
                }
                view.player = nil
                clearedViewCount += 1
            }
        }

    }

    /// Removes a player (called when explicitly disposed)
    func removePlayer(for controllerId: Int) {

        // First stop all views using this player
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
    }

    /// Clears all players (e.g., on logout)
    func clearAll() {
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
    }

    // MARK: - AirPlay Route Detection

    /// Starts global AirPlay route detection
    /// This monitors AirPlay device availability across the entire app
    @available(iOS 11.0, *)
    func startAirPlayRouteDetection() {

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


        // Send initial availability state
        if let isAvailable = globalRouteDetector?.multipleRoutesDetected {
            sendAirPlayAvailabilityEvent(isAvailable: isAvailable)
        }
    }

    /// Stops global AirPlay route detection
    @available(iOS 11.0, *)
    func stopAirPlayRouteDetection() {

        guard let detector = globalRouteDetector else {
            return
        }

        detector.removeObserver(self, forKeyPath: "multipleRoutesDetected")
        detector.isRouteDetectionEnabled = false
        globalRouteDetector = nil

    }

    /// Sends AirPlay availability event to Flutter through all registered views
    private func sendAirPlayAvailabilityEvent(isAvailable: Bool) {
        // Clean up nil/deallocated views first
        videoPlayerViews = videoPlayerViews.filter { $0.value.view != nil }


        // Send event through all registered views
        for (_, wrapper) in videoPlayerViews {
            if let view = wrapper.view {
                view.sendEvent("airPlayAvailabilityChanged", data: ["isAvailable": isAvailable])
            }
        }
    }

    /// KVO observer for route detector changes
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "multipleRoutesDetected" {
            if #available(iOS 11.0, *) {
                if let isAvailable = globalRouteDetector?.multipleRoutesDetected {
                    sendAirPlayAvailabilityEvent(isAvailable: isAvailable)
                }
            }
        }
    }
    
    /// Register a VideoPlayerView instance
    /// Multiple views can be registered for the same controller (e.g., list + detail screen)
    func registerVideoPlayerView(_ view: VideoPlayerView, viewId: Int64) {
        let key = "\(viewId)"
        videoPlayerViews[key] = WeakVideoPlayerViewWrapper(view: view)
    }
    
    /// Unregister a VideoPlayerView when it's disposed
    func unregisterVideoPlayerView(viewId: Int64) {
        let key = "\(viewId)"
        videoPlayerViews.removeValue(forKey: key)
    }

    /// Find another active view for a given controller (excluding a specific viewId)
    /// Returns the view instance if found, nil otherwise
    func findAnotherViewForController(_ controllerId: Int, excluding excludedViewId: Int64) -> VideoPlayerView? {
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
        return controllerWithAutomaticPiP == controllerId
    }

    /// Mark that manual PiP is active for a controller
    func setManualPiPActive(_ controllerId: Int, active: Bool) {
        if active {
            controllersWithManualPiP.insert(controllerId)
        } else {
            controllersWithManualPiP.remove(controllerId)
        }
    }

    /// Check if manual PiP is active for a controller
    func isManualPiPActive(_ controllerId: Int) -> Bool {
        return controllersWithManualPiP.contains(controllerId)
    }

    /// Store the active PiP controller for a given controller ID.
    /// This allows PiP to be exited even after the originating view is disposed.
    @available(iOS 14.0, *)
    func setActivePipController(_ pipController: AVPictureInPictureController, for controllerId: Int) {
        activePipControllers[controllerId] = pipController
    }

    /// Clear the active PiP controller for a given controller ID.
    @available(iOS 14.0, *)
    func clearActivePipController(for controllerId: Int) {
        activePipControllers.removeValue(forKey: controllerId)
    }

    /// Get the active PiP controller for a given controller ID, if any.
    @available(iOS 14.0, *)
    func getActivePipController(for controllerId: Int) -> AVPictureInPictureController? {
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
        primaryViewIdForController[controllerId] = viewId
    }

    /// Check if a specific view is the primary view for a controller
    func isPrimaryView(_ viewId: Int64, for controllerId: Int) -> Bool {
        return primaryViewIdForController[controllerId] == viewId
    }

    /// Get the primary view ID for a controller (if any)
    func getPrimaryViewId(for controllerId: Int) -> Int64? {
        return primaryViewIdForController[controllerId]
    }
    
    /// Enable automatic PiP for a specific controller and disable for all others
    /// This ensures only one player can enter automatic PiP at a time
    /// IMPORTANT: Only enables on the MOST RECENT (primary) view for that controller
    @available(iOS 14.2, *)
    func setAutomaticPiPEnabled(for controllerId: Int, enabled: Bool) {
        // Clean up nil/deallocated views first
        videoPlayerViews = videoPlayerViews.filter { $0.value.view != nil }
        
        if enabled {
            // Check if manual PiP is active for this controller
            if isManualPiPActive(controllerId) {
                return
            }

            // Disable automatic PiP on all other controllers first
            if let previousControllerId = controllerWithAutomaticPiP, previousControllerId != controllerId {
                // Disable on ALL platform views for the previous controller
                for (_, wrapper) in videoPlayerViews {
                    if let view = wrapper.view, view.controllerId == previousControllerId {
                        view.playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
                    }
                }
            }
            
            // Find the PRIMARY (most recently played) platform view for this controller
            
            // First, disable ALL views for this controller
            for (_, wrapper) in videoPlayerViews {
                if let view = wrapper.view, view.controllerId == controllerId {
                    view.playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
                }
            }

            // Then enable ONLY the primary view (the one that most recently called play)
            var enabledOnView = false
            if let primaryViewId = primaryViewIdForController[controllerId] {
                let key = "\(primaryViewId)"
                if let wrapper = videoPlayerViews[key], let view = wrapper.view {
                    if view.canStartPictureInPictureAutomatically {
                        view.playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
                        enabledOnView = true
                    }
                }
            }

            // FALLBACK: If no primary view was found or it was disposed, pick ANY view for this controller
            // This handles the case where the primary view was disposed but other views still exist
            if !enabledOnView {
                for (_, wrapper) in videoPlayerViews {
                    if let view = wrapper.view, view.controllerId == controllerId {
                        if view.canStartPictureInPictureAutomatically {
                            view.playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
                            // Set this as the new primary view
                            primaryViewIdForController[controllerId] = view.viewId
                            enabledOnView = true
                            break
                        }
                    }
                }
            }

            // Only set controllerWithAutomaticPiP if we actually enabled a view
            if enabledOnView {
                controllerWithAutomaticPiP = controllerId
            }
        } else {
            // Disable automatic PiP for ALL platform views of the specified controller
            for (_, wrapper) in videoPlayerViews {
                if let view = wrapper.view, view.controllerId == controllerId {
                    view.playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
                }
            }
            
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
