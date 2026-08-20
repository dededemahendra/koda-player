import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Built on first use rather than in `applicationDidFinishLaunching`. Opening a file
    /// from Finder delivers `application(_:open:)` *before* that callback runs, so a
    /// window controller created there does not exist yet when the file arrives, and
    /// every double-click ended in a nil unwrap.
    private lazy var windowController: PlayerWindowController = {
        let controller = PlayerWindowController()
        controller.playerViewController.applySavedPreferences()
        if Preferences.floatOnTop {
            controller.window?.level = .floating
        }
        return controller
    }()

    private var playerViewController: PlayerViewController {
        windowController.playerViewController
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.build(target: self)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let url = urlFromLaunchArguments() {
            playerViewController.open(url: url)
        }
    }

    /// Supports `Koda Player /path/to/video.mkv` and `Koda Player https://…` from a
    /// terminal. Finder and the dock go through `application(_:open:)` instead.
    private func urlFromLaunchArguments() -> URL? {
        for argument in CommandLine.arguments.dropFirst() {
            // Skip the process-serial-number flag LaunchServices passes.
            guard !argument.hasPrefix("-") else { continue }
            let path = (argument as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            // Anything that names a host is handed to mpv as-is, same as ⌘L does.
            if let url = URL(string: argument), let scheme = url.scheme, scheme != "file", url.host != nil {
                return url
            }
        }
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        playerViewController.prepareForTermination()
    }

    // Files opened from Finder, the dock, or `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { SupportedMedia.isPlayable($0) }) ?? urls.first else { return }
        windowController.showWindow(nil)
        playerViewController.open(url: url)
    }

    // MARK: - NSMenuDelegate

    /// Both dynamic submenus are rebuilt each time they open: Open Recent so files played
    /// this session show up without relaunching, Chapters because they belong to whatever
    /// file is loaded right now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.identifier {
        case MainMenuBuilder.recentFilesMenuIdentifier:
            rebuildRecentFilesMenu(menu)
        case MainMenuBuilder.chaptersMenuIdentifier:
            playerViewController.populateChapterMenu(menu)
        case MainMenuBuilder.aspectMenuIdentifier:
            playerViewController.populateAspectMenu(menu)
        case MainMenuBuilder.adjustmentsMenuIdentifier:
            playerViewController.populateAdjustmentsMenu(menu)
        default:
            break
        }
    }

    private func rebuildRecentFilesMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        for url in RecentFiles.urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentFile(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            item.toolTip = url.path
            item.isEnabled = FileManager.default.fileExists(atPath: url.path)
            menu.addItem(item)
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let clearItem = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentFiles(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
    }

    // MARK: - Menu actions

    @objc func openDocument(_ sender: Any?) {
        playerViewController.openPanel()
    }

    @objc func openSubtitle(_ sender: Any?) {
        playerViewController.openSubtitlePanel()
    }

    @objc func openRecentFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        playerViewController.open(url: url)
    }

    @objc func clearRecentFiles(_ sender: Any?) {
        RecentFiles.clear()
    }

    @objc func openURL(_ sender: Any?) {
        playerViewController.openURLPanel()
    }

    @objc func togglePlayback(_ sender: Any?) {
        playerViewController.player.togglePause()
    }

    @objc func stopPlayback(_ sender: Any?) {
        playerViewController.player.stop()
    }

    @objc func seekBackward(_ sender: Any?) {
        playerViewController.player.seek(by: -5)
    }

    @objc func seekForward(_ sender: Any?) {
        playerViewController.player.seek(by: 5)
    }

    @objc func nextItem(_ sender: Any?) {
        playerViewController.playAdjacentItem(offset: 1)
    }

    @objc func previousItem(_ sender: Any?) {
        playerViewController.playAdjacentItem(offset: -1)
    }

    @objc func previousChapter(_ sender: Any?) {
        playerViewController.stepChapter(by: -1)
    }

    @objc func nextChapter(_ sender: Any?) {
        playerViewController.stepChapter(by: 1)
    }

    @objc func setLoopPoint(_ sender: Any?) {
        playerViewController.cycleLoopPoint()
    }

    @objc func clearLoop(_ sender: Any?) {
        playerViewController.clearLoop()
    }

    @objc func increaseSpeed(_ sender: Any?) {
        let player = playerViewController.player
        player.setSpeed(player.state.speed + 0.25)
    }

    @objc func decreaseSpeed(_ sender: Any?) {
        let player = playerViewController.player
        player.setSpeed(player.state.speed - 0.25)
    }

    @objc func resetSpeed(_ sender: Any?) {
        playerViewController.player.setSpeed(1)
    }

    @objc func increaseVolume(_ sender: Any?) {
        playerViewController.player.adjustVolume(by: 5)
    }

    @objc func decreaseVolume(_ sender: Any?) {
        playerViewController.player.adjustVolume(by: -5)
    }

    @objc func toggleMute(_ sender: Any?) {
        playerViewController.player.toggleMute()
    }

    @objc func decreaseAudioDelay(_ sender: Any?) {
        playerViewController.adjustDelay(by: -0.1, audio: true)
    }

    @objc func increaseAudioDelay(_ sender: Any?) {
        playerViewController.adjustDelay(by: 0.1, audio: true)
    }

    @objc func decreaseSubtitleDelay(_ sender: Any?) {
        playerViewController.adjustDelay(by: -0.1, audio: false)
    }

    @objc func increaseSubtitleDelay(_ sender: Any?) {
        playerViewController.adjustDelay(by: 0.1, audio: false)
    }

    @objc func resetSync(_ sender: Any?) {
        playerViewController.resetSync()
    }

    @objc func cycleAspect(_ sender: Any?) {
        playerViewController.cycleAspect()
    }

    @objc func zoomIn(_ sender: Any?) {
        playerViewController.adjustZoom(by: 0.1)
    }

    @objc func zoomOut(_ sender: Any?) {
        playerViewController.adjustZoom(by: -0.1)
    }

    @objc func fillScreen(_ sender: Any?) {
        playerViewController.toggleFillScreen()
    }

    @objc func resetPicture(_ sender: Any?) {
        playerViewController.resetPicture()
    }

    @objc func cycleSubtitles(_ sender: Any?) {
        playerViewController.player.cycleSubtitles()
    }

    @objc func takeScreenshot(_ sender: Any?) {
        playerViewController.player.takeScreenshot()
    }

    @objc func halfSize(_ sender: Any?) {
        playerViewController.resizeWindow(toScale: 0.5)
    }

    @objc func actualSize(_ sender: Any?) {
        playerViewController.resizeWindow(toScale: 1)
    }

    @objc func doubleSize(_ sender: Any?) {
        playerViewController.resizeWindow(toScale: 2)
    }

    @objc func toggleFullScreen(_ sender: Any?) {
        playerViewController.toggleFullScreen()
    }

    @objc func toggleFloatOnTop(_ sender: NSMenuItem) {
        guard let window = windowController.window else { return }
        let isFloating = window.level == .floating
        window.level = isFloating ? .normal : .floating
        Preferences.floatOnTop = !isFloating
    }

    @objc func toggleRepeat(_ sender: Any?) {
        playerViewController.toggleRepeat()
    }

    @objc func toggleInfoPanel(_ sender: Any?) {
        playerViewController.toggleInfoPanel()
    }

    @objc func togglePlaylist(_ sender: Any?) {
        playerViewController.togglePlaylist()
    }

    /// Keeps the checkmarks on the toggles honest. Each one can also be flipped from the
    /// keyboard or the control bar, so the menu cannot own the state.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleFloatOnTop(_:)):
            item.state = windowController.window?.level == .floating ? .on : .off
        case #selector(toggleRepeat(_:)):
            item.state = playerViewController.isRepeating ? .on : .off
        case #selector(toggleInfoPanel(_:)):
            item.state = playerViewController.isInfoPanelVisible ? .on : .off
        case #selector(togglePlaylist(_:)):
            item.state = playerViewController.isPlaylistVisible ? .on : .off
        default:
            break
        }
        return true
    }
}

/// Builds the menu bar in code, with no nib and no Xcode project.
enum MainMenuBuilder {
    static func build(target: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenu())
        mainMenu.addItem(fileMenu(target: target))
        mainMenu.addItem(playbackMenu(target: target))
        mainMenu.addItem(videoMenu(target: target))
        mainMenu.addItem(audioMenu(target: target))
        mainMenu.addItem(subtitlesMenu(target: target))
        mainMenu.addItem(viewMenu(target: target))
        mainMenu.addItem(windowMenu())
        return mainMenu
    }

    private static func container(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = target
        return menuItem
    }

    private static func appMenu() -> NSMenuItem {
        let name = "Koda Player"
        return container(name, [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
        ])
    }

    static let recentFilesMenuIdentifier = NSUserInterfaceItemIdentifier("KodaRecentFiles")
    static let chaptersMenuIdentifier = NSUserInterfaceItemIdentifier("KodaChapters")
    static let aspectMenuIdentifier = NSUserInterfaceItemIdentifier("KodaAspect")
    static let adjustmentsMenuIdentifier = NSUserInterfaceItemIdentifier("KodaAdjustments")

    private static func fileMenu(target: AppDelegate) -> NSMenuItem {
        let recentItem = container("Open Recent", [])
        recentItem.submenu?.identifier = recentFilesMenuIdentifier
        recentItem.submenu?.delegate = target

        return container("File", [
            item("Open…", #selector(AppDelegate.openDocument(_:)), "o", target: target),
            item("Open URL…", #selector(AppDelegate.openURL(_:)), "l", target: target),
            recentItem,
            .separator(),
            item("Open Subtitle File…", #selector(AppDelegate.openSubtitle(_:)), "o", modifiers: [.command, .shift], target: target),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w")
        ])
    }

    private static func playbackMenu(target: AppDelegate) -> NSMenuItem {
        let chaptersItem = container("Chapters", [])
        chaptersItem.submenu?.identifier = chaptersMenuIdentifier
        chaptersItem.submenu?.delegate = target

        return container("Playback", [
            item("Play / Pause", #selector(AppDelegate.togglePlayback(_:)), "p", target: target),
            item("Stop", #selector(AppDelegate.stopPlayback(_:)), ".", target: target),
            .separator(),
            item("Step Back 5s", #selector(AppDelegate.seekBackward(_:)), "[", target: target),
            item("Step Forward 5s", #selector(AppDelegate.seekForward(_:)), "]", target: target),
            .separator(),
            item("Previous in Folder", #selector(AppDelegate.previousItem(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), target: target),
            item("Next in Folder", #selector(AppDelegate.nextItem(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), target: target),
            .separator(),
            chaptersItem,
            item("Previous Chapter", #selector(AppDelegate.previousChapter(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: [.command, .option], target: target),
            item("Next Chapter", #selector(AppDelegate.nextChapter(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: [.command, .option], target: target),
            .separator(),
            item("Set Loop Point", #selector(AppDelegate.setLoopPoint(_:)), "r", target: target),
            item("Clear Loop", #selector(AppDelegate.clearLoop(_:)), "r", modifiers: [.command, .shift], target: target),
            item("Repeat File", #selector(AppDelegate.toggleRepeat(_:)), "l", modifiers: [.command, .option], target: target),
            .separator(),
            item("Speed Up", #selector(AppDelegate.increaseSpeed(_:)), "=", target: target),
            item("Slow Down", #selector(AppDelegate.decreaseSpeed(_:)), "-", target: target),
            item("Normal Speed", #selector(AppDelegate.resetSpeed(_:)), "0", target: target)
        ])
    }

    /// Aspect and the colour adjustments are rebuilt on open so their checkmarks track
    /// whatever the picture is actually set to; the rest are static so their shortcuts
    /// work without the menu ever having been opened.
    private static func videoMenu(target: AppDelegate) -> NSMenuItem {
        let aspectItem = container("Aspect Ratio", [])
        aspectItem.submenu?.identifier = aspectMenuIdentifier
        aspectItem.submenu?.delegate = target

        let adjustmentsItem = container("Adjustments", [])
        adjustmentsItem.submenu?.identifier = adjustmentsMenuIdentifier
        adjustmentsItem.submenu?.delegate = target

        return container("Video", [
            aspectItem,
            item("Cycle Aspect Ratio", #selector(AppDelegate.cycleAspect(_:)), "a", modifiers: [.command, .option], target: target),
            .separator(),
            item("Zoom In", #selector(AppDelegate.zoomIn(_:)), "=", modifiers: [.command, .option], target: target),
            item("Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-", modifiers: [.command, .option], target: target),
            item("Fill Window", #selector(AppDelegate.fillScreen(_:)), "f", modifiers: [.command, .option], target: target),
            .separator(),
            adjustmentsItem,
            item("Reset Picture", #selector(AppDelegate.resetPicture(_:)), "p", modifiers: [.command, .shift], target: target)
        ])
    }

    private static func audioMenu(target: AppDelegate) -> NSMenuItem {
        container("Audio", [
            item("Volume Up", #selector(AppDelegate.increaseVolume(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), target: target),
            item("Volume Down", #selector(AppDelegate.decreaseVolume(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), target: target),
            item("Mute", #selector(AppDelegate.toggleMute(_:)), "m", target: target),
            .separator(),
            item("Audio Delay −0.1s", #selector(AppDelegate.decreaseAudioDelay(_:)), target: target),
            item("Audio Delay +0.1s", #selector(AppDelegate.increaseAudioDelay(_:)), target: target),
            item("Reset Sync", #selector(AppDelegate.resetSync(_:)), "0", modifiers: [.command, .option], target: target)
        ])
    }

    private static func subtitlesMenu(target: AppDelegate) -> NSMenuItem {
        container("Subtitles", [
            item("Cycle Subtitle Track", #selector(AppDelegate.cycleSubtitles(_:)), "v", target: target),
            item("Add Subtitle File…", #selector(AppDelegate.openSubtitle(_:)), target: target),
            .separator(),
            item("Subtitle Delay −0.1s", #selector(AppDelegate.decreaseSubtitleDelay(_:)), target: target),
            item("Subtitle Delay +0.1s", #selector(AppDelegate.increaseSubtitleDelay(_:)), target: target),
            item("Reset Sync", #selector(AppDelegate.resetSync(_:)), target: target)
        ])
    }

    private static func viewMenu(target: AppDelegate) -> NSMenuItem {
        container("View", [
            item("Half Size", #selector(AppDelegate.halfSize(_:)), "1", target: target),
            item("Actual Size", #selector(AppDelegate.actualSize(_:)), "2", target: target),
            item("Double Size", #selector(AppDelegate.doubleSize(_:)), "3", target: target),
            .separator(),
            item("Enter / Exit Full Screen", #selector(AppDelegate.toggleFullScreen(_:)), "f", modifiers: [.command, .control], target: target),
            item("Float on Top", #selector(AppDelegate.toggleFloatOnTop(_:)), "t", target: target),
            item("Playlist", #selector(AppDelegate.togglePlaylist(_:)), "p", modifiers: [.command, .option], target: target),
            item("Media Info", #selector(AppDelegate.toggleInfoPanel(_:)), "i", target: target),
            .separator(),
            item("Save Screenshot", #selector(AppDelegate.takeScreenshot(_:)), "s", target: target)
        ])
    }

    private static func windowMenu() -> NSMenuItem {
        let menuItem = container("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)))
        ])
        NSApp.windowsMenu = menuItem.submenu
        return menuItem
    }
}
