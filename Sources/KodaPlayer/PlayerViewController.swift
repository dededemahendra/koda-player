import AppKit
import UniformTypeIdentifiers

/// Root view: hosts the mpv surface, the overlay controls, drag-and-drop and keyboard input.
final class PlayerContainerView: NSView {
    var onMouseMoved: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onClick: ((Int) -> Void)?
    var onDropURLs: (([URL]) -> Void)?
    var onMagnify: ((NSEvent) -> Void)?
    var onSmartMagnify: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?()
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseMoved?()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }

    // MARK: - Trackpad

    /// Pinch. Delivered as a stream of small deltas with a phase, not an absolute scale.
    override func magnify(with event: NSEvent) {
        onMagnify?(event)
    }

    /// Two-finger double tap.
    override func smartMagnify(with event: NSEvent) {
        onSmartMagnify?()
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDropURLs?(urls)
        return true
    }

    private func droppedURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { SupportedMedia.isPlayable($0) || SupportedMedia.isSubtitle($0) || $0.hasDirectoryPath }
    }
}

final class PlayerViewController: NSViewController {
    let player = MPVPlayer()

    private var videoView: MPVVideoView!
    private let controls = ControlsView()
    private let placeholder = PlaceholderView()
    private let osd = OSDView()
    private let infoPanel = InfoPanelView()
    private let nowPlaying = NowPlayingController()
    private let playlistPanel = PlaylistView()
    private var controlsTrailingConstraint: NSLayoutConstraint!

    private var hideControlsWorkItem: DispatchWorkItem?
    private var pendingClickWorkItem: DispatchWorkItem?
    private var currentURL: URL?
    private var didRestorePosition = false
    private var playlist: [URL] = []
    private var infoRefreshTimer: Timer?
    private var gestureBaseWidth: Double?
    private var gestureTravel: CGFloat = 0
    private var gestureDidCrossFullScreen = false
    private var lastPersisted: (volume: Double, isMuted: Bool, picture: PictureSettings)?

    private let controlsAutoHideDelay: TimeInterval = 2.5

    // MARK: - Lifecycle

    override func loadView() {
        let container = PlayerContainerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        container.onMouseMoved = { [weak self] in self?.revealControls() }
        container.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        container.onClick = { [weak self] clickCount in self?.handleClick(count: clickCount) }
        container.onDropURLs = { [weak self] urls in self?.handleDroppedURLs(urls) }
        container.onMagnify = { [weak self] event in
            self?.magnifyWindow(
                by: event.magnification,
                phase: event.phase,
                zoomsPicture: event.modifierFlags.contains(.option)
            )
        }
        container.onSmartMagnify = { [weak self] in self?.toggleFullScreen() }
        view = container

        videoView = MPVVideoView(player: player)
        videoView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(videoView)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(placeholder)

        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.delegate = self
        container.addSubview(controls)

        osd.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(osd)

        infoPanel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(infoPanel)

        playlistPanel.translatesAutoresizingMaskIntoConstraints = false
        playlistPanel.delegate = self
        container.addSubview(playlistPanel)

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            controls.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            osd.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            osd.topAnchor.constraint(equalTo: container.topAnchor, constant: 60),

            // Below the floating titlebar, clear of the centred OSD.
            infoPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            infoPanel.topAnchor.constraint(equalTo: container.topAnchor, constant: 46),
            infoPanel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.6),

            playlistPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            playlistPanel.topAnchor.constraint(equalTo: container.topAnchor, constant: 46),
            playlistPanel.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            playlistPanel.widthAnchor.constraint(equalToConstant: Self.playlistWidth)
        ])

        // Held onto so the control bar can step aside when the queue is showing.
        controlsTrailingConstraint = controls.trailingAnchor.constraint(
            equalTo: container.trailingAnchor,
            constant: -16
        )
        controlsTrailingConstraint.isActive = true

        player.delegate = self
        controls.update(with: player.state)

        nowPlaying.start()
        nowPlaying.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .play: self.player.setPaused(false)
            case .pause: self.player.setPaused(true)
            case .toggle: self.player.togglePause()
            case .seek(let position):
                self.player.seek(to: position)
                self.nowPlaying.republishPosition(position)
            case .skip(let delta): self.player.seek(by: delta)
            case .next: self.playAdjacentItem(offset: 1)
            case .previous: self.playAdjacentItem(offset: -1)
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
        revealControls()
    }

    // MARK: - Opening media

    /// `reseedPlaylist` is what separates a queue from a folder walk: opening a file from
    /// Finder or ⌘O rebuilds the queue around it, but playing a row of the existing queue
    /// must leave that queue alone.
    func open(url: URL, reseedPlaylist: Bool = true) {
        if SupportedMedia.isSubtitle(url) {
            player.addSubtitleFile(url)
            osd.show("Subtitle added")
            return
        }
        saveResumePosition()
        currentURL = url
        didRestorePosition = false
        player.open(url: url)
        placeholder.isHidden = true
        updateWindowTitle()
        // A stream has no folder to walk and no file for the recents menu to check for,
        // so both of those stay file-only.
        if url.isFileURL {
            RecentFiles.add(url)
            if reseedPlaylist { buildPlaylistFromSiblings(of: url) }
        } else if reseedPlaylist {
            playlist = []
        }
        refreshPlaylistPanel()
        revealControls()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SupportedMedia.openPanelContentTypes
        panel.allowsOtherFileTypes = true          // mpv can often play things macOS can't name
        panel.message = "Choose a video or audio file"
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    /// ⌘L. mpv opens network sources exactly like local ones, so this only has to collect
    /// the text, prefilled from the clipboard when that looks like a link.
    func openURLPanel() {
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "Play a stream or a video hosted somewhere else."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://example.com/stream.m3u8"
        field.stringValue = Self.urlStringFromPasteboard() ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme != nil, url.host != nil || url.isFileURL else {
            osd.show("That is not a URL Koda can open", duration: 2.5)
            return
        }
        open(url: url)
    }

    private static func urlStringFromPasteboard() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let scheme = URL(string: text)?.scheme?.lowercased(),
              ["http", "https", "rtmp", "rtmps", "rtsp", "smb", "ftp", "mms", "udp", "srt"].contains(scheme)
        else { return nil }
        return text
    }

    func openSubtitlePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a subtitle file"
        if panel.runModal() == .OK, let url = panel.url {
            player.addSubtitleFile(url)
            osd.show("Subtitle added")
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        if let subtitle = urls.first(where: { SupportedMedia.isSubtitle($0) }), player.state.hasFile {
            player.addSubtitleFile(subtitle)
            osd.show("Subtitle added")
            return
        }
        let playable = Self.expandPlayable(urls)
        guard let first = playable.first else { return }
        open(url: first)

        // Everything dropped alongside the first file joins the queue instead of being lost.
        let extras = playable.dropFirst().filter { !playlist.contains($0) }
        guard !extras.isEmpty else { return }
        playlist.append(contentsOf: extras)
        refreshPlaylistPanel()
        osd.show("Added \(extras.count) to the queue")
    }

    /// Turns a drop into playable files, in the order they would play. A dropped folder
    /// contributes its contents rather than being handed to mpv as a file.
    private static func expandPlayable(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            guard url.hasDirectoryPath else {
                return SupportedMedia.isPlayable(url) ? [url] : []
            }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return sortedByName(contents.filter { SupportedMedia.isPlayable($0) })
        }
    }

    private static func sortedByName(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Lets ⌘→ / ⌘← walk through the other videos in the same folder.
    private func buildPlaylistFromSiblings(of url: URL) {
        let folder = url.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        playlist = Self.sortedByName(contents.filter { SupportedMedia.isPlayable($0) })
    }

    func playAdjacentItem(offset: Int) {
        guard let currentURL, let index = playlist.firstIndex(of: currentURL) else { return }
        let target = index + offset
        guard playlist.indices.contains(target) else {
            osd.show(offset > 0 ? "End of folder" : "Start of folder")
            return
        }
        open(url: playlist[target], reseedPlaylist: false)
    }

    // MARK: - Controls visibility

    private func revealControls() {
        hideControlsWorkItem?.cancel()
        setControlsHidden(false)

        guard player.state.hasFile, !player.state.isPaused else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.controls.isScrubbing else { return }
            guard !self.isMouseOverControls else { return }
            self.setControlsHidden(true)
        }
        hideControlsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + controlsAutoHideDelay, execute: workItem)
    }

    private var isMouseOverControls: Bool {
        guard let window = view.window else { return false }
        let mousePoint = controls.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return controls.bounds.contains(mousePoint)
    }

    private func setControlsHidden(_ hidden: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            controls.animator().alphaValue = hidden ? 0 : 1
        }
        if hidden, view.window?.styleMask.contains(.fullScreen) == true {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        view.window?.standardWindowButton(.closeButton)?.superview?.animator().alphaValue = hidden ? 0 : 1
    }

    // MARK: - Input

    private func handleClick(count: Int) {
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
    private func handleKey(_ event: NSEvent) -> Bool {
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

    private func subtitleStatusText() -> String {
        player.refreshTracks()
        if let track = player.state.selectedTrack(of: .sub) {
            return "Subtitles: \(track.displayName)"
        }
        return "Subtitles off"
    }

    // MARK: - Chapters, looping and sync

    func stepChapter(by offset: Int) {
        guard player.state.hasFile else { return }
        guard !player.state.chapters.isEmpty else {
            osd.show("No chapters in this file")
            return
        }
        if let chapter = player.stepChapter(by: offset) {
            osd.show(chapter.displayName)
        } else {
            osd.show(offset > 0 ? "Last chapter" : "First chapter")
        }
        revealControls()
    }

    func cycleLoopPoint() {
        switch player.cycleLoopPoint() {
        case .start(let start):
            osd.show("Loop start \(TimeFormatter.string(from: start))")
        case .range(let start, let end):
            osd.show("Loop \(TimeFormatter.string(from: start)) – \(TimeFormatter.string(from: end))")
        case .cleared:
            osd.show("Loop cleared")
        }
        revealControls()
    }

    func clearLoop() {
        guard player.state.hasLoop else { return }
        player.clearLoop()
        osd.show("Loop cleared")
        revealControls()
    }

    func adjustDelay(by delta: Double, audio: Bool) {
        guard player.state.hasFile else { return }
        let value = audio ? player.adjustAudioDelay(by: delta) : player.adjustSubtitleDelay(by: delta)
        osd.show(String(format: "%@ delay %+.2fs", audio ? "Audio" : "Subtitle", value))
        revealControls()
    }

    func resetSync() {
        player.resetSync()
        osd.show("Sync reset")
        revealControls()
    }

    // MARK: - Playlist

    static let playlistWidth: CGFloat = 300

    var isPlaylistVisible: Bool { !playlistPanel.isHidden }

    func togglePlaylist() {
        setPlaylistVisible(playlistPanel.isHidden)
    }

    private func setPlaylistVisible(_ visible: Bool) {
        playlistPanel.isHidden = !visible
        if visible { refreshPlaylistPanel() }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            controlsTrailingConstraint.animator().constant = visible ? -(Self.playlistWidth + 24) : -16
            view.layoutSubtreeIfNeeded()
        }

        if !visible {
            // The table takes focus when it is clicked; give the keys back on the way out.
            view.window?.makeFirstResponder(view)
        }
        revealControls()
    }

    private func refreshPlaylistPanel() {
        playlistPanel.update(items: playlist, current: currentURL)
    }

    // MARK: - Repeat

    func toggleRepeat() {
        guard player.state.hasFile else { return }
        osd.show(player.toggleLoopFile() ? "Repeat on" : "Repeat off")
        revealControls()
    }

    var isRepeating: Bool { player.state.isLoopingFile }

    /// Whether the Mac is being held awake for playback right now.
    var isPreventingSleep: Bool { nowPlaying.isPreventingSleep }

    // MARK: - Media info

    var isInfoPanelVisible: Bool { !infoPanel.isHidden }

    func toggleInfoPanel() {
        guard player.state.hasFile else {
            osd.show("Nothing playing")
            return
        }
        setInfoPanelVisible(infoPanel.isHidden)
    }

    private func setInfoPanelVisible(_ visible: Bool) {
        infoRefreshTimer?.invalidate()
        infoRefreshTimer = nil
        infoPanel.isHidden = !visible
        guard visible else { return }

        refreshInfoPanel()
        // Bitrate, dropped frames and cache only mean anything while they move.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshInfoPanel()
        }
        RunLoop.main.add(timer, forMode: .common)
        infoRefreshTimer = timer
    }

    private func refreshInfoPanel() {
        guard !infoPanel.isHidden else { return }
        infoPanel.update(with: player.mediaInfo())
    }

    // MARK: - Preferences

    /// Restores the settings that describe the listener rather than the file.
    func applySavedPreferences() {
        player.setVolume(Preferences.volume)
        if Preferences.isMuted { player.toggleMute() }
        for adjustment in PictureAdjustment.allCases {
            let value = Preferences.adjustment(adjustment.rawValue)
            if value != 0 { player.setAdjustment(adjustment, to: value) }
        }
        lastPersisted = (Preferences.volume, Preferences.isMuted, player.state.picture)
    }

    /// Called on every state change, so it compares against what was last written instead
    /// of touching the defaults on each time-pos tick.
    private func persistPreferences() {
        let current = player.state
        if let last = lastPersisted,
           last.volume == current.volume, last.isMuted == current.isMuted, last.picture == current.picture {
            return
        }
        lastPersisted = (current.volume, current.isMuted, current.picture)
        Preferences.volume = current.volume
        Preferences.isMuted = current.isMuted
        for adjustment in PictureAdjustment.allCases {
            Preferences.setAdjustment(adjustment.rawValue, current.picture.value(of: adjustment))
        }
    }

    // MARK: - Picture

    func cycleAspect() {
        guard player.state.hasVideoTrack else { return }
        osd.show("Aspect \(player.cycleAspectOverride().label)")
        revealControls()
    }

    func setAspect(_ preset: AspectPreset) {
        player.setAspectOverride(preset.value)
        osd.show("Aspect \(preset.label)")
        revealControls()
    }

    func adjustZoom(by delta: Double) {
        guard player.state.hasVideoTrack else { return }
        player.adjustZoom(by: delta)
        osd.show("Zoom \(Self.percent(player.state.picture.zoomScale))")
        revealControls()
    }

    func adjustPanscan(by delta: Double) {
        guard player.state.hasVideoTrack else { return }
        let value = player.adjustPanscan(by: delta)
        osd.show(value == 0 ? "Fit to window" : "Fill \(Self.percent(value))")
        revealControls()
    }

    /// One key for the common case: crop to fill the window, or go back to letterboxing.
    func toggleFillScreen() {
        guard player.state.hasVideoTrack else { return }
        let fill = player.state.picture.panscan < 1
        player.setPanscan(fill ? 1 : 0)
        osd.show(fill ? "Filling window" : "Fit to window")
        revealControls()
    }

    func setAdjustment(_ adjustment: PictureAdjustment, to value: Int) {
        let landed = player.setAdjustment(adjustment, to: value)
        osd.show("\(adjustment.label) \(Self.signed(landed))")
        revealControls()
    }

    func nudgeAdjustment(_ adjustment: PictureAdjustment, by delta: Int) {
        let landed = player.adjust(adjustment, by: delta)
        osd.show("\(adjustment.label) \(Self.signed(landed))")
        revealControls()
    }

    func resetPicture() {
        player.resetPicture()
        osd.show("Picture reset")
        revealControls()
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private static func signed(_ value: Int) -> String {
        value == 0 ? "0" : String(format: "%+d", value)
    }

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

    // MARK: - Window plumbing

    func toggleFullScreen() {
        view.window?.toggleFullScreen(nil)
    }

    private var currentTitle: String {
        player.state.mediaTitle.isEmpty
            ? (currentURL?.lastPathComponent ?? "Koda Player")
            : player.state.mediaTitle
    }

    private func updateWindowTitle() {
        view.window?.title = currentTitle
        view.window?.representedURL = currentURL
    }

    /// Sizes the window to the video, capped to the visible screen area.
    private func resizeWindowToVideo() {
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
    private func dumpStateIfRequested() {
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

// MARK: - Player delegate

extension PlayerViewController: MPVPlayerDelegate {
    func playerStateDidChange(_ player: MPVPlayer) {
        controls.update(with: player.state)
        placeholder.isHidden = player.state.hasFile
        persistPreferences()
        nowPlaying.update(with: player.state, title: currentTitle)
        nowPlaying.updateSleepPrevention(
            isPlaying: player.state.hasFile && !player.state.isPaused,
            hasVideo: player.state.hasVideoTrack
        )
    }

    func playerDidLoadFile(_ player: MPVPlayer) {
        updateWindowTitle()
        refreshInfoPanel()
        refreshPlaylistPanel()
        resizeWindowToVideo()
        dumpStateIfRequested()

        if !didRestorePosition, let currentURL, let saved = ResumeStore.position(for: currentURL) {
            didRestorePosition = true
            player.seek(to: saved)
            osd.show("Resumed at \(TimeFormatter.string(from: saved))")
        }
    }

    func playerDidEndFile(_ player: MPVPlayer, reason: MPVPlayer.EndReason) {
        switch reason {
        case .finished:
            saveResumePosition()
            // mpv restarts the file itself when loop-file is on; walking to the next one
            // here would fight it.
            guard !player.state.isLoopingFile else { return }
            playAdjacentItem(offset: 1)
        case .error(let message):
            osd.show("Could not play file: \(message)", duration: 4)
            placeholder.isHidden = false
        case .stopped:
            break
        }
    }
}

// MARK: - Playlist delegate

extension PlayerViewController: PlaylistViewDelegate {
    func playlistDidChoose(_ url: URL) {
        open(url: url, reseedPlaylist: false)
    }

    func playlistDidChange(to urls: [URL]) {
        playlist = urls
        refreshPlaylistPanel()
    }

    func playlistDidReceive(_ urls: [URL]) {
        let additions = urls.filter { !playlist.contains($0) }
        guard !additions.isEmpty else { return }
        playlist.append(contentsOf: additions)
        refreshPlaylistPanel()
        osd.show(additions.count == 1 ? "Added to the queue" : "Added \(additions.count) to the queue")

        // Dropping files in with nothing loaded should start playing, not just queue up.
        if !player.state.hasFile, let first = additions.first {
            open(url: first, reseedPlaylist: false)
        }
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

// MARK: - Small overlay views

/// Shown when nothing is loaded.
private final class PlaceholderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let icon = NSImageView()
        icon.image = ControlsView.symbolImage("film.stack", size: 52)
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.55)

        let title = NSTextField(labelWithString: "Drop a video here")
        title.font = .systemFont(ofSize: 19, weight: .medium)
        title.textColor = NSColor.white.withAlphaComponent(0.85)
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "MKV · MP4 · AVI · MOV · WMV · FLV · TS · WebM and more  ·  ⌘O to browse")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.45)
        subtitle.alignment = .center

        let stack = NSStackView(views: [icon, title, subtitle])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Transient message overlay for volume, speed and seek feedback.
private final class OSDView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var dismissWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        alphaValue = 0

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ text: String, duration: TimeInterval = 1.2) {
        label.stringValue = text
        dismissWorkItem?.cancel()
        alphaValue = 1

        let workItem = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self?.animator().alphaValue = 0
            }
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Payloads for the picture menu items, carried in `representedObject`.
private struct AdjustmentTarget {
    let adjustment: PictureAdjustment
    let value: Int
}

private struct AdjustmentNudge {
    let adjustment: PictureAdjustment
    let delta: Int
}

private enum MenuSection {
    /// Uses the real section header on macOS 14+, falls back to a disabled item before that.
    static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
