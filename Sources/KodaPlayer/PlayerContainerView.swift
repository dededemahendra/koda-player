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
