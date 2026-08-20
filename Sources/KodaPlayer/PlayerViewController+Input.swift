import AppKit

/// Everything the keyboard and the mouse do to the player.
extension PlayerViewController {
    // MARK: - Input

    func handleClick(count: Int) {
        pendingClickWorkItem?.cancel()
        if count >= 2 {
            toggleFullScreen()
            return
        }
        // Wait out the double-click window before treating it as play/pause.
        let workItem = DispatchWorkItem { [weak self] in self?.player.togglePause() }
        pendingClickWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
    }

    /// Returns true when the key was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command) else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 49: // space
            player.togglePause()
            revealControls()
            return true
        case 123: // left arrow
            seekRelative(shift ? -60 : -5)
            return true
        case 124: // right arrow
            seekRelative(shift ? 60 : 5)
            return true
        case 126: // up arrow
            adjustVolume(by: 5)
            return true
        case 125: // down arrow
            adjustVolume(by: -5)
            return true
        case 53: // escape
            if view.window?.styleMask.contains(.fullScreen) == true {
                toggleFullScreen()
                return true
            }
            return false
        default:
            break
        }

        switch characters {
        case "k":
            player.togglePause()
            revealControls()
        case "j":
            seekRelative(-10)
        case "l":
            if shift {
                toggleRepeat()
            } else {
                seekRelative(10)
            }
        case "i":
            toggleInfoPanel()
        case "p":
            togglePlaylist()
        case "f":
            toggleFullScreen()
        case "m":
            player.toggleMute()
            osd.show(player.state.isMuted ? "Muted" : "Unmuted")
            revealControls()
        case "s":
            player.takeScreenshot()
            osd.show("Screenshot saved to Desktop")
        case "[":
            changeSpeed(by: -0.25)
        case "]":
            changeSpeed(by: 0.25)
        case "\u{8}", "\u{7f}": // backspace / delete
            player.setSpeed(1)
            osd.show("Speed 1.00×")
        case ",":
            player.step(frames: -1)
        case ".":
            player.step(frames: 1)
        case "v":
            player.cycleSubtitles()
            osd.show(subtitleStatusText())
        case "<":
            stepChapter(by: -1)
        case ">":
            stepChapter(by: 1)
        case "r":
            cycleLoopPoint()
        case "z":
            adjustDelay(by: -0.1, audio: shift)
        case "x":
            adjustDelay(by: 0.1, audio: shift)
        case "a":
            cycleAspect()
        case "=", "+":
            adjustZoom(by: 0.1)
        case "-", "_":
            adjustZoom(by: -0.1)
        case "w":
            adjustPanscan(by: -0.1)
        case "e":
            adjustPanscan(by: 0.1)
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            guard let digit = Double(characters), player.state.duration > 0 else { return true }
            player.seek(to: player.state.duration * digit / 10)
            revealControls()
        default:
            return false
        }
        return true
    }

    private func seekRelative(_ seconds: Double) {
        guard player.state.hasFile else { return }
        player.seek(by: seconds)
        nowPlaying.republishPosition(player.state.position + seconds)
        osd.show(seconds > 0 ? "▶︎ \(Int(seconds))s" : "◀︎ \(Int(abs(seconds)))s")
        revealControls()
    }

    private func adjustVolume(by delta: Double) {
        player.adjustVolume(by: delta)
        let newVolume = max(0, min(130, player.state.volume + delta))
        osd.show("Volume \(Int(newVolume))%")
        revealControls()
    }

    private func changeSpeed(by delta: Double) {
        let speed = max(0.25, min(4, player.state.speed + delta))
        player.setSpeed(speed)
        osd.show(String(format: "Speed %.2f×", speed))
        revealControls()
    }

    func subtitleStatusText() -> String {
        player.refreshTracks()
        if let track = player.state.selectedTrack(of: .sub) {
            return "Subtitles: \(track.displayName)"
        }
        return "Subtitles off"
    }
}
