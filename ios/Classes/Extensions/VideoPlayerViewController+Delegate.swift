import AVKit

extension VideoPlayerView: AVPlayerViewControllerDelegate {
    public func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {

        // Mark PiP as active
        isPipCurrentlyActive = true

        // Disable automatic inline PiP while PiP is active
        // This prevents the system from trying to trigger automatic PiP again
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: false)
            }
        }

        // Ensure this view owns the remote commands when entering PiP
        // This is critical because the PiP window needs working media controls
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

        // Send through per-view event channel (legacy)
        sendEvent("pipStart", data: ["isPictureInPicture": true])

        // Send through controller-level event channel (persists when views disposed)
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.sendControllerEvent(
                "pipStart",
                data: ["isPictureInPicture": true],
                for: controllerIdValue
            )
        }
    }

    public func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    }

    public func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {

        // Send pipStop event BEFORE PiP actually stops
        // This gives Flutter time to react before the native PiP window closes

        // Send through per-view event channel (legacy)
        if eventSink != nil {
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        } else if let controllerIdValue = controllerId {
            // Try any view for this controller
            let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            for view in allViews where view.eventSink != nil {
                view.sendEvent("pipStop", data: ["isPictureInPicture": false])
                break
            }
        }

        // Send through controller-level event channel (persists when views disposed)
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.sendControllerEvent(
                "pipStop",
                data: ["isPictureInPicture": false],
                for: controllerIdValue
            )
        }
    }

    public func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {

        // Determine if this was a manual PiP stop
        let wasManualPiP = controllerId.flatMap { SharedPlayerManager.shared.isManualPiPActive($0) } ?? false

        // Mark PiP as inactive
        isPipCurrentlyActive = false

        // Clear stored PiP controller reference
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.clearActivePipController(for: controllerIdValue)
        }

        // Clear manual PiP flag if this was a manual PiP session
        if wasManualPiP, let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
        }

        // Re-establish ownership and Now Playing info when PiP stops
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
        } else {
            // Try to find ANY view with this controller that has media info
            if let controllerIdValue = controllerId {
                let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
                for view in allViews {
                    if let viewMediaInfo = view.currentMediaInfo {
                        currentMediaInfo = viewMediaInfo
                        setupNowPlayingInfo(mediaInfo: viewMediaInfo)
                        break
                    }
                }
            }
        }

        // Re-enable automatic PiP if this was a MANUAL PiP session and automatic PiP was requested
        // For automatic PiP sessions, it will auto re-enable when video plays again
        if #available(iOS 14.2, *) {
            if wasManualPiP, let controllerIdValue = controllerId, canStartPictureInPictureAutomatically {
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
            }
        }

        // Emit current state to sync UI after PiP stops
        // Note: pipStop event was already sent in willStopPictureInPicture
        if eventSink != nil {
            emitCurrentState()
        } else if let controllerIdValue = controllerId {
            // Try any view for this controller
            let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            for view in allViews where view.eventSink != nil {
                view.emitCurrentState()
                break
            }
        }
    }

    public func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
    }
    
    // This delegate method is called when automatic PiP is about to start (iOS 14.2+)
    // No @available annotation needed as the method is optional in the protocol
    public func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        // Return false to keep the view visible when automatic PiP starts
        // Return true to dismiss the view controller when PiP starts automatically
        return false
    }
    
    // Handle when the user dismisses fullscreen by swiping down or tapping Done
    @available(iOS 13.0, *)
    public func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        // Store the playback state before dismissing
        let wasPlaying = self.player?.rate != 0
        
        // Send fullscreen exit event when user dismisses fullscreen
        coordinator.animate(alongsideTransition: nil) { _ in
            // Check if this is the fullscreen view controller we're tracking
            if playerViewController == self.fullscreenPlayerViewController {
                // Release the video layer from the fullscreen VC as the presentation is ending
                playerViewController.player = nil
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
            }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
@available(iOS 14.0, *)
extension VideoPlayerView: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {

        // Mark PiP as active
        isPipCurrentlyActive = true

        // Store the PiP controller in SharedPlayerManager so it survives view disposal
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setActivePipController(pictureInPictureController, for: controllerIdValue)
        }

        // Disable automatic inline PiP while PiP is active
        // This prevents the system from trying to trigger automatic PiP again
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: false)
            }
        }

        // Ensure player view stays visible and keeps playing
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0

        // Ensure this view owns the remote commands when entering PiP
        // This is critical because the PiP window needs working media controls
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

        // Send through per-view event channel (legacy)
        sendEvent("pipStart", data: ["isPictureInPicture": true])

        // Send through controller-level event channel (persists when views disposed)
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.sendControllerEvent(
                "pipStart",
                data: ["isPictureInPicture": true],
                for: controllerIdValue
            )
        }
    }

    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {

        // Make sure the player view is still visible after PiP starts
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0

        // Ensure audio session stays active for background PiP playback
        prepareAudioSession()

        // Resume if paused (don't gate on readyToPlay — AVPlayer queues the play)
        if let player = player, player.rate == 0 {
            player.play()
        }

        // Delayed check: the AVPlayerViewController may pause the player AFTER this
        // delegate fires (because allowsPictureInPicturePlayback was set to false,
        // and the app is transitioning to background). Catch that delayed pause.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isPipCurrentlyActive else { return }
            self.prepareAudioSession()
            if let player = self.player, player.rate == 0 {
                player.play()
            }
        }
    }
    
    public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {

        // Send pipStop event BEFORE PiP actually stops
        // This gives Flutter time to react before the native PiP window closes

        // Send through per-view event channel (legacy)
        if eventSink != nil {
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        } else if let controllerIdValue = controllerId {
            // Try any view for this controller
            let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            for view in allViews where view.eventSink != nil {
                view.sendEvent("pipStop", data: ["isPictureInPicture": false])
                break
            }
        }

        // Send through controller-level event channel (persists when views disposed)
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.sendControllerEvent(
                "pipStop",
                data: ["isPictureInPicture": false],
                for: controllerIdValue
            )
        }
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {

        // Mark PiP as inactive
        isPipCurrentlyActive = false

        // Clear stored PiP controller reference
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.clearActivePipController(for: controllerIdValue)
        }

        // Ensure player view is visible after exiting PiP
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0

        // Clear manual PiP flag before re-enabling anything
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
        }

        // Re-enable AVPlayerViewController's PiP management
        // This was disabled when manual PiP started to prevent conflicts
        if let controllerIdValue = controllerId {
            if let pipSettings = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue) {
                playerViewController.allowsPictureInPicturePlayback = pipSettings.allowsPictureInPicture
            } else {
                playerViewController.allowsPictureInPicturePlayback = true
            }
        }

        // Destroy the custom PiP controller so it doesn't interfere with automatic PiP
        pipController = nil

        // Re-establish ownership and Now Playing info when PiP stops
        var mediaInfo = currentMediaInfo

        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                currentMediaInfo = mediaInfo
            }
        }

        if let mediaInfo = mediaInfo {
            // Force re-registration of remote commands because PiP might have cleared them
            forceReregisterRemoteCommands()
        } else {
            // Try to find ANY view with this controller that has media info
            if let controllerIdValue = controllerId {
                let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
                for view in allViews {
                    if let viewMediaInfo = view.currentMediaInfo {
                        currentMediaInfo = viewMediaInfo
                        setupNowPlayingInfo(mediaInfo: viewMediaInfo)
                        break
                    }
                }
            }
        }

        // Re-enable automatic PiP ALWAYS if automatic PiP was requested
        // Don't check if playing - let the system handle it
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId {

                // Check both the view's setting AND the shared settings
                if canStartPictureInPictureAutomatically {
                    SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                } else if let pipSettings = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue),
                          pipSettings.canStartPictureInPictureAutomatically {
                    SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                }
            }
        }

        // Emit current state to sync UI after PiP stops
        // Note: pipStop event was already sent in willStopPictureInPicture
        if eventSink != nil {
            emitCurrentState()
        } else if let controllerIdValue = controllerId {
            // Try any view for this controller
            let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            for view in allViews where view.eventSink != nil {
                view.emitCurrentState()
                break
            }
        }
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        // Ensure view is visible if PiP fails
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {

        // CRITICAL: Get media info from SharedPlayerManager FIRST before anything else
        // This ensures we have it even if views are being disposed/recreated during app foregrounding
        var mediaInfoFromCache: [String: Any]?
        if let controllerIdValue = controllerId {
            mediaInfoFromCache = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
        }

        // Check if we have an event sink (indicates the view is still active)
        if eventSink != nil {
            // Restore the player view
            playerViewController.view.isHidden = false
            playerViewController.view.alpha = 1.0

            // CRITICAL: Re-establish Now Playing info when restoring from background
            // Use cached media info (most reliable) or fall back to current view's media info
            let mediaInfo = mediaInfoFromCache ?? currentMediaInfo

            if let mediaInfo = mediaInfo {
                currentMediaInfo = mediaInfo
                setupNowPlayingInfo(mediaInfo: mediaInfo)
            }

            completionHandler(true)
            return
        }

        // Original view has been disposed — try to find another active view
        if let controllerIdValue = controllerId,
           let alternativeView = SharedPlayerManager.shared.findAnotherViewForController(controllerIdValue, excluding: viewId) {

            alternativeView.playerViewController.view.isHidden = false
            alternativeView.playerViewController.view.alpha = 1.0

            let mediaInfo = mediaInfoFromCache ?? alternativeView.currentMediaInfo
            if let mediaInfo = mediaInfo {
                alternativeView.currentMediaInfo = mediaInfo
                alternativeView.setupNowPlayingInfo(mediaInfo: mediaInfo)
            }

            completionHandler(true)
        } else {
            // No alternative view — iOS will gracefully exit PiP
            completionHandler(false)
        }
    }
}