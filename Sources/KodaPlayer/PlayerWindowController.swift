import AppKit

/// Window that keeps the video edge-to-edge: the titlebar floats over the picture and
/// fades out together with the controls.
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    let playerViewController = PlayerViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Koda Player"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.minSize = NSSize(width: 480, height: 300)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.setFrameAutosaveName("KodaPlayerWindow")

        super.init(window: window)

        window.contentViewController = playerViewController
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }

    // MARK: - NSWindowDelegate

    func windowDidEnterFullScreen(_ notification: Notification) {
        playerViewController.windowDidChangeFullScreen(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        playerViewController.windowDidChangeFullScreen(false)
    }

    func windowWillClose(_ notification: Notification) {
        playerViewController.saveResumePosition()
    }
}
