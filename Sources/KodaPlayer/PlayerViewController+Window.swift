import AppKit

/// Window sizing, full screen, the pinch gesture, and the diagnostics dump.
extension PlayerViewController {
    // MARK: - Window plumbing

    func toggleFullScreen() {
        view.window?.toggleFullScreen(nil)
    }

    var currentTitle: String {
        player.state.mediaTitle.isEmpty
            ? (currentURL?.lastPathComponent ?? "Koda Player")
            : player.state.mediaTitle
    }

    func updateWindowTitle() {
        view.window?.title = currentTitle
        view.window?.representedURL = currentURL
    }

    /// Sizes the window to the video, capped to the visible screen area.
    func resizeWindowToVideo() {
        guard let window = view.window, player.state.hasVideoTrack else { return }
        window.contentAspectRatio = NSSize(width: player.state.aspectRatio, height: 1)
        applyVideoSize(scale: 1)
    }

    // MARK: - Pinch to resize

    static let minimumWindowWidth: Double = 480
    /// How far a pinch has to travel, past the point where the window can grow no further,
    /// before it means "full screen". High enough that ordinary resizing never trips it.
    private static let fullScreenGestureThreshold: CGFloat = 0.25

    /// Pinch scales the window rather than the picture; the window's `contentAspectRatio`
    /// keeps the video's shape, so only the width has to be driven. Holding ⌥ zooms the
    /// picture inside the window instead, which is the other thing a pinch could mean.
    func magnifyWindow(by magnification: CGFloat, phase: NSEvent.Phase, zoomsPicture: Bool = false) {
        guard !zoomsPicture else {
            adjustZoom(by: Double(magnification))
            return
        }
        guard let window = view.window else { return }

        switch phase {
        case .began:
            gestureBaseWidth = Double(window.frame.width)
            gestureTravel = 0
            gestureDidCrossFullScreen = false

        case .changed:
            gestureTravel += magnification
            guard !gestureDidCrossFullScreen else { return }

            // Nothing to resize in full screen, so a firm pinch inwards leaves it.
            guard !window.styleMask.contains(.fullScreen) else {
                if gestureTravel <= -Self.fullScreenGestureThreshold {
                    gestureDidCrossFullScreen = true
                    toggleFullScreen()
                }
                return
            }

            let base = gestureBaseWidth ?? Double(window.frame.width)
            let atMaximum = applyWindowWidth(base * (1 + Double(gestureTravel)))
            if atMaximum, gestureTravel >= Self.fullScreenGestureThreshold {
                gestureDidCrossFullScreen = true
                toggleFullScreen()
            }

        case .ended, .cancelled:
            defer { gestureBaseWidth = nil }
            guard !gestureDidCrossFullScreen, player.state.hasVideoTrack,
                  !window.styleMask.contains(.fullScreen) else { return }
            let scale = Double(window.frame.width) / Double(player.state.videoWidth)
            osd.show("Window \(Int((scale * 100).rounded()))%")

        default:
            break
        }
    }

    /// Sets the window's content width, keeping it centred and inside the screen.
    /// Returns whether it came out clamped at the largest size that fits.
    @discardableResult
    private func applyWindowWidth(_ width: Double) -> Bool {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return false }

        let maxWidth = Double(screen.visibleFrame.width) * 0.95
        let clamped = max(Self.minimumWindowWidth, min(width, maxWidth))
        let height = clamped / player.state.aspectRatio

        let current = window.frame
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: clamped, height: height))
        frame.origin = NSPoint(x: current.midX - frame.width / 2, y: current.midY - frame.height / 2)
        window.setFrame(frame, display: true)

        return clamped >= maxWidth - 0.5
    }

    /// ⌘1 / ⌘2 / ⌘3: a multiple of the video's own resolution, still capped to the screen.
    func resizeWindow(toScale scale: Double) {
        guard player.state.hasVideoTrack else {
            osd.show("Nothing playing")
            return
        }
        applyVideoSize(scale: scale)
        osd.show("Window \(Int(scale * 100))%")
        revealControls()
    }

    private func applyVideoSize(scale: Double) {
        guard let window = view.window, !window.styleMask.contains(.fullScreen) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        let aspect = player.state.aspectRatio
        let maxSize = screen.visibleFrame.size
        var width = Double(player.state.videoWidth) * scale
        var height = Double(player.state.videoHeight) * scale
        // Never larger than the screen, whatever was asked for.
        let clamp = min(1, min((maxSize.width * 0.9) / width, (maxSize.height * 0.9) / height))
        width = max(width * clamp, Self.minimumWindowWidth)
        height = max(height * clamp, Self.minimumWindowWidth / aspect)

        let currentFrame = window.frame
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
        frame.origin = NSPoint(
            x: currentFrame.midX - frame.width / 2,
            y: currentFrame.midY - frame.height / 2
        )
        window.setFrame(frame.intersects(screen.visibleFrame) ? frame : currentFrame, display: true, animate: true)
    }

    func saveResumePosition() {
        guard let currentURL, player.state.duration > 0 else { return }
        ResumeStore.save(position: player.state.position, duration: player.state.duration, for: currentURL)
    }

    /// Diagnostic hook, mirroring `KODA_FRAME_DUMP`: set `KODA_STATE_DUMP=/path/state.json`
    /// to write out what the player thinks it loaded: resolution, duration and tracks.
    func dumpStateIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["KODA_STATE_DUMP"] else { return }
        // Duration and track details land through property observers just after the file
        // loads, so snapshot a moment later to capture the state the UI actually sees.
        // `KODA_STATE_DUMP_DELAY` pushes that sample further out, which is how chapter,
        // loop and sync changes made from the keyboard can be inspected.
        let delay = environment["KODA_STATE_DUMP_DELAY"].flatMap(Double.init) ?? 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.writeStateDump(to: path)
        }
    }

    private func writeStateDump(to path: String) {
        let state = player.state
        let payload: [String: Any] = [
            "file": currentURL?.lastPathComponent ?? "",
            "width": state.videoWidth,
            "height": state.videoHeight,
            "duration": state.duration,
            "position": state.position,
            "paused": state.isPaused,
            "buffering": state.isBuffering,
            "currentChapter": state.currentChapter,
            "repeating": state.isLoopingFile,
            "playlist": playlist.map { $0.lastPathComponent },
            "playlistVisible": isPlaylistVisible,
            "preventingSleep": isPreventingSleep,
            "info": player.mediaInfo().map { ["label": $0.label, "value": $0.value] },
            "loopStart": state.loopStart ?? NSNull(),
            "loopEnd": state.loopEnd ?? NSNull(),
            "subtitleDelay": state.subtitleDelay,
            "audioDelay": state.audioDelay,
            "picture": [
                "aspectOverride": state.picture.aspectOverride,
                "zoom": state.picture.zoom,
                "panscan": state.picture.panscan,
                "brightness": state.picture.brightness,
                "contrast": state.picture.contrast,
                "saturation": state.picture.saturation,
                "gamma": state.picture.gamma
            ] as [String: Any],
            "chapters": state.chapters.map { chapter in
                [
                    "index": chapter.index,
                    "title": chapter.title ?? "",
                    "start": chapter.start
                ] as [String: Any]
            },
            "tracks": state.tracks.map { track in
                [
                    "id": track.id,
                    "kind": track.kind.rawValue,
                    "codec": track.codec ?? "",
                    "lang": track.lang ?? "",
                    "selected": track.isSelected,
                    "label": track.displayName
                ] as [String: Any]
            }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func prepareForTermination() {
        infoRefreshTimer?.invalidate()
        infoRefreshTimer = nil
        nowPlaying.clear()
        nowPlaying.endActivity()
        saveResumePosition()
        videoView.destroyRenderContext()
        player.shutdown()
    }

    func windowDidChangeFullScreen(_ isFullScreen: Bool) {
        controls.setFullScreen(isFullScreen)
        revealControls()
    }
}
