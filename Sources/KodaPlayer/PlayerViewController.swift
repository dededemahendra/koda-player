import AppKit
import UniformTypeIdentifiers

final class PlayerViewController: NSViewController {
    let player = MPVPlayer()

    var videoView: MPVVideoView!
    let controls = ControlsView()
    private let placeholder = PlaceholderView()
    let osd = OSDView()
    private let infoPanel = InfoPanelView()
    let nowPlaying = NowPlayingController()
    private let playlistPanel = PlaylistView()
    private var controlsTrailingConstraint: NSLayoutConstraint!

    private var hideControlsWorkItem: DispatchWorkItem?
    var pendingClickWorkItem: DispatchWorkItem?
    var currentURL: URL?
    private var didRestorePosition = false
    var playlist: [URL] = []
    var infoRefreshTimer: Timer?
    var gestureBaseWidth: Double?
    var gestureTravel: CGFloat = 0
    var gestureDidCrossFullScreen = false
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

    func revealControls() {
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

    static func signed(_ value: Int) -> String {
        value == 0 ? "0" : String(format: "%+d", value)
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
