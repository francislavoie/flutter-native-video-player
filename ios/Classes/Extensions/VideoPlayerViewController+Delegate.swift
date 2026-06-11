import AVKit

// MARK: - Shared PiP Lifecycle Helpers
extension VideoPlayerView {
    /// Shared logic for PiP willStart (both auto and manual PiP)
    func handlePipWillStart() {
        isPipCurrentlyActive = true

        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: false)
            }
        }

        var mediaInfo = currentMediaInfo
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                currentMediaInfo = mediaInfo
            }
        }
        if let mediaInfo = mediaInfo {
            setupNowPlayingInfo(mediaInfo: mediaInfo)
        }

        sendEvent("pipStart", data: ["isPictureInPicture": true])
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.sendControllerEvent(
                "pipStart",
                data: ["isPictureInPicture": true],
                for: controllerIdValue
            )
        }
    }

    /// Shared logic for sending pipStop event (both auto and manual PiP)
    func sendPipStopEvent() {
        if eventSink != nil {
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        } else if let controllerIdValue = controllerId {
            let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            for view in allViews where view.eventSink != nil {
                view.sendEvent("pipStop", data: ["isPictureInPicture": false])
                break
            }
        }

        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.sendControllerEvent(
                "pipStop",
                data: ["isPictureInPicture": false],
                for: controllerIdValue
            )
        }
    }

    /// Shared logic for PiP didStop (both auto and manual PiP).
    /// Returns wasManualPiP for callers that need protocol-specific cleanup.
    @discardableResult
    func handlePipDidStop() -> Bool {
        let wasManualPiP = controllerId.flatMap { SharedPlayerManager.shared.isManualPiPActive($0) } ?? false

        isPipCurrentlyActive = false

        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.clearActivePipController(for: controllerIdValue)
        }

        if wasManualPiP, let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
        }

        // Emit pipStop now that isPipCurrentlyActive is false. Emitting earlier
        // (from WillStop) would race with teardown; the playback-state refresh
        // below intentionally skips PiP to avoid a duplicate.
        sendPipStopEvent()

        var mediaInfo = currentMediaInfo
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                currentMediaInfo = mediaInfo
            }
        }

        if let mediaInfo = mediaInfo {
            setupNowPlayingInfo(mediaInfo: mediaInfo)
        } else if let controllerIdValue = controllerId {
            let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            for view in allViews {
                if let viewMediaInfo = view.currentMediaInfo {
                    currentMediaInfo = viewMediaInfo
                    setupNowPlayingInfo(mediaInfo: viewMediaInfo)
                    break
                }
            }
        }

        if eventSink != nil {
            emitPlaybackState()
        } else if let controllerIdValue = controllerId {
            let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            for view in allViews where view.eventSink != nil {
                view.emitPlaybackState()
                break
            }
        }

        return wasManualPiP
    }
}

extension VideoPlayerView: AVPlayerViewControllerDelegate {
    public func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        // Safety fallback — canStartPictureInPictureAutomaticallyFromInline is kept false,
        // so this delegate should not fire. All PiP goes through our custom controller.
        handlePipWillStart()
    }

    public func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    }

    public func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        // pipStop is emitted from handlePipDidStop() once isPipCurrentlyActive
        // has been cleared — emitting here would race with the actual teardown.
    }

    public func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        handlePipDidStop()

        // Keep allowsPictureInPicturePlayback = false — all PiP goes through
        // our custom AVPictureInPictureController, not the AVPlayerViewController.
        // Leaving it true causes the system to start auto PiP we can't stop.
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
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setActivePipController(pictureInPictureController, for: controllerIdValue)
        }

        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0

        handlePipWillStart()
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
        // pipStop is emitted from handlePipDidStop() once isPipCurrentlyActive
        // has been cleared — emitting here would race with the actual teardown.
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        // Ensure player view is visible after exiting PiP
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0

        // Keep allowsPictureInPicturePlayback = false and pipController alive — all PiP
        // goes through our custom AVPictureInPictureController. Keeping it alive means
        // the next background PiP starts immediately (fresh controllers need warmup).

        let wasManualPiP = handlePipDidStop()

        // Force re-registration of remote commands because PiP might have cleared them
        if currentMediaInfo != nil {
            forceReregisterRemoteCommands()
        }

        // Re-enable background PiP tracking
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId, canStartPictureInPictureAutomatically {
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
            }
        }
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        // Ensure view is visible if PiP fails
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0

        // A failed start can leave isPipCurrentlyActive set and the manual-PiP
        // flag stuck on; route through the did-stop path to clean up and
        // notify Dart. Without this, auto-PiP stays permanently blocked.
        handlePipDidStop()

        // WillStart may have fired and disabled auto-PiP — re-enable it.
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId, canStartPictureInPictureAutomatically {
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
            }
        }
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
