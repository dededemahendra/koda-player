import AppKit

/// Every menu the player builds itself: the control bar's subtitle and gear menus, the
/// chapter list, and the picture menus the `Video` menu shares.
extension PlayerViewController {
    // MARK: - Picture menus

    private func aspectItems() -> [NSMenuItem] {
        let current = AspectPreset.matching(player.state.picture.aspectOverride)
        return AspectPreset.allCases.map { preset in
            let item = NSMenuItem(title: preset.label, action: #selector(selectAspect(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset
            item.state = preset == current ? .on : .off
            return item
        }
    }

    /// One submenu per colour knob, its parent title carrying the current value so the
    /// whole picture state is readable without opening anything.
    private func adjustmentItems() -> [NSMenuItem] {
        PictureAdjustment.allCases.map { adjustment in
            let value = player.state.picture.value(of: adjustment)
            let parent = NSMenuItem(title: "\(adjustment.label)  \(Self.signed(value))", action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            for (title, delta) in [("Decrease", -5), ("Increase", 5)] {
                let item = NSMenuItem(title: title, action: #selector(nudgeAdjustmentItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = AdjustmentNudge(adjustment: adjustment, delta: delta)
                submenu.addItem(item)
            }
            submenu.addItem(.separator())

            for preset in [-50, -25, -10, 0, 10, 25, 50] {
                let item = NSMenuItem(title: Self.signed(preset), action: #selector(selectAdjustment(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = AdjustmentTarget(adjustment: adjustment, value: preset)
                item.state = value == preset ? .on : .off
                submenu.addItem(item)
            }

            parent.submenu = submenu
            return parent
        }
    }

    private func framingItems() -> [NSMenuItem] {
        let picture = player.state.picture
        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(zoomInItem), keyEquivalent: "")
        let zoomOut = NSMenuItem(title: "Zoom Out", action: #selector(zoomOutItem), keyEquivalent: "")
        let fill = NSMenuItem(title: picture.panscan >= 1 ? "Fit to Window" : "Fill Window",
                              action: #selector(fillScreenItem), keyEquivalent: "")
        for item in [zoomIn, zoomOut, fill] { item.target = self }
        return [zoomIn, zoomOut, fill]
    }

    func populateAspectMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        aspectItems().forEach(menu.addItem)
    }

    func populateAdjustmentsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        adjustmentItems().forEach(menu.addItem)
    }

    /// The control bar's Picture submenu: aspect, framing and colour in one place, rebuilt
    /// every time the gear menu opens so the checkmarks are current.
    func pictureMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuSection.header("Aspect Ratio"))
        aspectItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(MenuSection.header("Framing"))
        framingItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(MenuSection.header("Adjustments"))
        adjustmentItems().forEach(menu.addItem)
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset Picture", action: #selector(resetPictureItem), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = !player.state.picture.isUntouched
        menu.addItem(reset)
        return menu
    }

    @objc private func selectAspect(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? AspectPreset else { return }
        setAspect(preset)
    }

    @objc private func selectAdjustment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? AdjustmentTarget else { return }
        setAdjustment(target.adjustment, to: target.value)
    }

    @objc private func nudgeAdjustmentItem(_ sender: NSMenuItem) {
        guard let nudge = sender.representedObject as? AdjustmentNudge else { return }
        nudgeAdjustment(nudge.adjustment, by: nudge.delta)
    }

    @objc private func zoomInItem() { adjustZoom(by: 0.1) }
    @objc private func zoomOutItem() { adjustZoom(by: -0.1) }
    @objc private func fillScreenItem() { toggleFillScreen() }
    @objc private func resetPictureItem() { resetPicture() }

    /// Fills a menu with the current file's chapters. Shared by the control bar's gear
    /// menu and the Playback ▸ Chapters submenu, which both rebuild on open.
    func populateChapterMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !player.state.chapters.isEmpty else {
            let empty = NSMenuItem(title: "No Chapters", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for chapter in player.state.chapters {
            let item = NSMenuItem(title: chapter.displayName, action: #selector(selectChapter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = chapter.index
            item.state = chapter.index == player.state.currentChapter ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func selectChapter(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        player.seekToChapter(index)
        if let chapter = player.state.chapters.first(where: { $0.index == index }) {
            osd.show(chapter.displayName)
        }
        revealControls()
    }
}

// MARK: - Controls delegate

extension PlayerViewController: ControlsViewDelegate {
    func controlsDidTogglePlayback() {
        player.togglePause()
        revealControls()
    }

    func controlsDidSeek(to seconds: Double, isScrubbing: Bool) {
        player.seek(to: seconds, exact: !isScrubbing)
        revealControls()
    }

    func controlsDidSetVolume(_ volume: Double) {
        if player.state.isMuted, volume > 0 { player.toggleMute() }
        player.setVolume(volume)
    }

    func controlsDidToggleMute() {
        player.toggleMute()
    }

    func controlsDidToggleFullScreen() {
        toggleFullScreen()
    }

    func controlsDidRequestSubtitleMenu(_ sender: NSView) {
        let menu = NSMenu()
        player.refreshTracks()

        let offItem = NSMenuItem(title: "Off", action: #selector(selectSubtitleTrack(_:)), keyEquivalent: "")
        offItem.target = self
        offItem.state = player.state.selectedTrack(of: .sub) == nil ? .on : .off
        menu.addItem(offItem)

        for track in player.state.tracks(of: .sub) {
            let item = NSMenuItem(title: track.displayName, action: #selector(selectSubtitleTrack(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = track
            item.state = track.isSelected ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let addItem = NSMenuItem(title: "Add Subtitle File…", action: #selector(addSubtitleFile), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)

        present(menu: menu, from: sender)
    }

    func controlsDidRequestSettingsMenu(_ sender: NSView) {
        let menu = NSMenu()
        player.refreshTracks()

        let audioTracks = player.state.tracks(of: .audio)
        if !audioTracks.isEmpty {
            menu.addItem(MenuSection.header("Audio Track"))
            for track in audioTracks {
                let item = NSMenuItem(title: track.displayName, action: #selector(selectAudioTrack(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = track
                item.state = track.isSelected ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        if !player.state.chapters.isEmpty {
            let chaptersItem = NSMenuItem(title: "Chapters", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            populateChapterMenu(submenu)
            chaptersItem.submenu = submenu
            menu.addItem(chaptersItem)
            menu.addItem(.separator())
        }

        let pictureItem = NSMenuItem(title: "Picture", action: nil, keyEquivalent: "")
        pictureItem.submenu = pictureMenu()
        pictureItem.isEnabled = player.state.hasVideoTrack
        menu.addItem(pictureItem)
        menu.addItem(.separator())

        menu.addItem(MenuSection.header("Speed"))
        for speed in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            let item = NSMenuItem(title: String(format: "%.2f×", speed), action: #selector(selectSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speed
            item.state = abs(player.state.speed - speed) < 0.01 ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let loopItem = NSMenuItem(
            title: loopMenuTitle(),
            action: #selector(toggleLoopPoint),
            keyEquivalent: ""
        )
        loopItem.target = self
        loopItem.isEnabled = player.state.hasFile
        menu.addItem(loopItem)

        let syncItem = NSMenuItem(title: "Reset Sync", action: #selector(resetSyncFromMenu), keyEquivalent: "")
        syncItem.target = self
        syncItem.isEnabled = player.state.subtitleDelay != 0 || player.state.audioDelay != 0
        menu.addItem(syncItem)

        menu.addItem(.separator())
        let repeatItem = NSMenuItem(title: "Repeat File", action: #selector(toggleRepeatItem), keyEquivalent: "")
        repeatItem.target = self
        repeatItem.state = player.state.isLoopingFile ? .on : .off
        repeatItem.isEnabled = player.state.hasFile
        menu.addItem(repeatItem)

        let infoItem = NSMenuItem(title: "Media Info", action: #selector(toggleInfoPanelItem), keyEquivalent: "")
        infoItem.target = self
        infoItem.state = isInfoPanelVisible ? .on : .off
        infoItem.isEnabled = player.state.hasFile
        menu.addItem(infoItem)

        menu.addItem(.separator())
        let screenshotItem = NSMenuItem(title: "Save Screenshot", action: #selector(saveScreenshot), keyEquivalent: "")
        screenshotItem.target = self
        menu.addItem(screenshotItem)

        present(menu: menu, from: sender)
    }

    private func present(menu: NSMenu, from view: NSView) {
        let origin = NSPoint(x: 0, y: -6)
        menu.popUp(positioning: nil, at: origin, in: view)
    }

    @objc private func selectSubtitleTrack(_ sender: NSMenuItem) {
        player.selectTrack(sender.representedObject as? Track, kind: .sub)
        osd.show(subtitleStatusText())
    }

    @objc private func selectAudioTrack(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track else { return }
        player.selectTrack(track, kind: .audio)
        osd.show("Audio: \(track.displayName)")
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? Double else { return }
        player.setSpeed(speed)
        osd.show(String(format: "Speed %.2f×", speed))
    }

    @objc private func addSubtitleFile() {
        openSubtitlePanel()
    }

    /// The A-B loop is one item whose label says what pressing it will do next.
    private func loopMenuTitle() -> String {
        let state = player.state
        if state.loopEnd != nil { return "Clear Loop" }
        if state.loopStart != nil { return "Set Loop End" }
        return "Set Loop Start"
    }

    @objc private func toggleLoopPoint() {
        cycleLoopPoint()
    }

    @objc private func resetSyncFromMenu() {
        resetSync()
    }

    @objc private func toggleRepeatItem() { toggleRepeat() }
    @objc private func toggleInfoPanelItem() { toggleInfoPanel() }

    @objc private func saveScreenshot() {
        player.takeScreenshot()
        osd.show("Screenshot saved to Desktop")
    }
}
