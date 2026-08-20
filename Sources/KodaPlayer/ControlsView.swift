import AppKit

/// Slider that jumps straight to the clicked position instead of paging towards it.
final class SeekSlider: NSSlider {
    var onScrubBegan: (() -> Void)?
    var onScrubEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onScrubBegan?()
        let point = convert(event.locationInWindow, from: nil)
        setValueFromPoint(point)
        sendAction(action, to: target)

        // Track the drag ourselves so scrubbing feels continuous.
        var isDragging = true
        while isDragging {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            switch next.type {
            case .leftMouseDragged:
                setValueFromPoint(convert(next.locationInWindow, from: nil))
                sendAction(action, to: target)
            case .leftMouseUp:
                isDragging = false
            default:
                break
            }
        }
        onScrubEnded?()
    }

    private func setValueFromPoint(_ point: NSPoint) {
        let usableWidth = max(1, bounds.width - knobThickness)
        let offset = min(max(0, point.x - knobThickness / 2), usableWidth)
        let fraction = Double(offset / usableWidth)
        doubleValue = minValue + fraction * (maxValue - minValue)
    }
}

protocol ControlsViewDelegate: AnyObject {
    func controlsDidTogglePlayback()
    func controlsDidSeek(to seconds: Double, isScrubbing: Bool)
    func controlsDidSetVolume(_ volume: Double)
    func controlsDidToggleMute()
    func controlsDidToggleFullScreen()
    func controlsDidRequestSubtitleMenu(_ sender: NSView)
    func controlsDidRequestSettingsMenu(_ sender: NSView)
}

/// The floating control bar. Auto-hiding is driven by `PlayerContainerView`.
final class ControlsView: NSVisualEffectView {
    weak var delegate: ControlsViewDelegate?

    private let playPauseButton = ControlsView.makeButton(symbol: "play.fill", size: 20)
    private let backButton = ControlsView.makeButton(symbol: "gobackward.10", size: 15)
    private let forwardButton = ControlsView.makeButton(symbol: "goforward.10", size: 15)
    private let muteButton = ControlsView.makeButton(symbol: "speaker.wave.2.fill", size: 13)
    private let subtitleButton = ControlsView.makeButton(symbol: "captions.bubble", size: 14)
    private let settingsButton = ControlsView.makeButton(symbol: "gearshape", size: 14)
    private let fullScreenButton = ControlsView.makeButton(symbol: "arrow.up.left.and.arrow.down.right", size: 13)

    private let positionLabel = ControlsView.makeLabel()
    private let durationLabel = ControlsView.makeLabel()
    private let seekSlider = SeekSlider()
    private let volumeSlider = NSSlider()
    private let loopBar = LoopBandView()

    private(set) var isScrubbing = false

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        buildLayout()
        wireActions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Layout

    private func buildLayout() {
        seekSlider.minValue = 0
        seekSlider.maxValue = 1
        seekSlider.doubleValue = 0
        seekSlider.isContinuous = true
        seekSlider.controlSize = .small
        seekSlider.isEnabled = false

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 130
        volumeSlider.doubleValue = 100
        volumeSlider.isContinuous = true
        volumeSlider.controlSize = .mini
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let transportStack = NSStackView(views: [backButton, playPauseButton, forwardButton])
        transportStack.spacing = 12
        transportStack.alignment = .centerY

        let volumeStack = NSStackView(views: [muteButton, volumeSlider])
        volumeStack.spacing = 6
        volumeStack.alignment = .centerY

        let trailingStack = NSStackView(views: [volumeStack, subtitleButton, settingsButton, fullScreenButton])
        trailingStack.spacing = 12
        trailingStack.alignment = .centerY

        let timelineStack = NSStackView(views: [positionLabel, seekSlider, durationLabel])
        timelineStack.spacing = 8
        timelineStack.alignment = .centerY
        timelineStack.setHuggingPriority(.defaultLow, for: .horizontal)
        seekSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bottomStack = NSStackView(views: [transportStack, NSView(), trailingStack])
        bottomStack.spacing = 12
        bottomStack.alignment = .centerY
        bottomStack.distribution = .fill

        let root = NSStackView(views: [timelineStack, bottomStack])
        root.orientation = .vertical
        root.spacing = 6
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            timelineStack.widthAnchor.constraint(equalTo: root.widthAnchor),
            bottomStack.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])

        loopBar.translatesAutoresizingMaskIntoConstraints = false
        loopBar.isHidden = true
        addSubview(loopBar)

        // Under the slider rather than on it: the knob would otherwise draw straight
        // through the band whenever the playhead sits inside the loop. The inset matches
        // half a knob, which is where the track actually starts and ends.
        NSLayoutConstraint.activate([
            loopBar.leadingAnchor.constraint(equalTo: seekSlider.leadingAnchor, constant: 6),
            loopBar.trailingAnchor.constraint(equalTo: seekSlider.trailingAnchor, constant: -6),
            loopBar.bottomAnchor.constraint(equalTo: seekSlider.bottomAnchor, constant: 1),
            loopBar.heightAnchor.constraint(equalToConstant: 3)
        ])
    }

    private func wireActions() {
        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayback)
        backButton.target = self
        backButton.action = #selector(skipBackward)
        forwardButton.target = self
        forwardButton.action = #selector(skipForward)
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        subtitleButton.target = self
        subtitleButton.action = #selector(showSubtitleMenu)
        settingsButton.target = self
        settingsButton.action = #selector(showSettingsMenu)
        fullScreenButton.target = self
        fullScreenButton.action = #selector(toggleFullScreen)

        seekSlider.target = self
        seekSlider.action = #selector(seekSliderChanged)
        seekSlider.onScrubBegan = { [weak self] in self?.isScrubbing = true }
        seekSlider.onScrubEnded = { [weak self] in
            guard let self else { return }
            self.isScrubbing = false
            self.delegate?.controlsDidSeek(to: self.seekSlider.doubleValue, isScrubbing: false)
        }

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged)
    }

    // MARK: - State

    func update(with state: PlaybackState) {
        let symbol = state.isPaused ? "play.fill" : "pause.fill"
        playPauseButton.image = ControlsView.symbolImage(symbol, size: 20)
        playPauseButton.isEnabled = state.hasFile

        seekSlider.isEnabled = state.hasFile && state.duration > 0
        if !isScrubbing {
            seekSlider.maxValue = max(state.duration, 0.001)
            seekSlider.doubleValue = state.position
        }
        positionLabel.stringValue = TimeFormatter.string(from: state.position)
        durationLabel.stringValue = TimeFormatter.string(from: state.duration)

        loopBar.configure(start: state.loopStart, end: state.loopEnd, duration: state.duration)

        volumeSlider.doubleValue = state.isMuted ? 0 : state.volume
        muteButton.image = ControlsView.symbolImage(volumeSymbol(for: state), size: 13)

        let subtitleTracks = state.tracks(of: .sub)
        subtitleButton.isEnabled = !subtitleTracks.isEmpty || state.hasFile
        let hasActiveSubtitle = state.selectedTrack(of: .sub) != nil
        subtitleButton.contentTintColor = hasActiveSubtitle ? .controlAccentColor : .white
    }

    private func volumeSymbol(for state: PlaybackState) -> String {
        if state.isMuted || state.volume <= 0 { return "speaker.slash.fill" }
        if state.volume < 40 { return "speaker.wave.1.fill" }
        if state.volume < 90 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    func setFullScreen(_ isFullScreen: Bool) {
        let symbol = isFullScreen
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        fullScreenButton.image = ControlsView.symbolImage(symbol, size: 13)
    }

    // MARK: - Actions

    @objc private func togglePlayback() {
        delegate?.controlsDidTogglePlayback()
    }

    @objc private func skipBackward() {
        delegate?.controlsDidSeek(to: max(0, seekSlider.doubleValue - 10), isScrubbing: false)
    }

    @objc private func skipForward() {
        delegate?.controlsDidSeek(to: min(seekSlider.maxValue, seekSlider.doubleValue + 10), isScrubbing: false)
    }

    @objc private func toggleMute() {
        delegate?.controlsDidToggleMute()
    }

    @objc private func toggleFullScreen() {
        delegate?.controlsDidToggleFullScreen()
    }

    @objc private func showSubtitleMenu() {
        delegate?.controlsDidRequestSubtitleMenu(subtitleButton)
    }

    @objc private func showSettingsMenu() {
        delegate?.controlsDidRequestSettingsMenu(settingsButton)
    }

    @objc private func seekSliderChanged() {
        positionLabel.stringValue = TimeFormatter.string(from: seekSlider.doubleValue)
        delegate?.controlsDidSeek(to: seekSlider.doubleValue, isScrubbing: true)
    }

    @objc private func volumeSliderChanged() {
        delegate?.controlsDidSetVolume(volumeSlider.doubleValue)
    }

    // MARK: - Factory helpers

    static func symbolImage(_ name: String, size: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private static func makeButton(symbol: String, size: CGFloat) -> NSButton {
        let button = NSButton(image: symbolImage(symbol, size: size) ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: size + 12).isActive = true
        button.heightAnchor.constraint(equalToConstant: size + 12).isActive = true
        return button
    }

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return label
    }
}

/// The A-B loop range, drawn as a slim accent band beneath the seek slider. A loop with
/// its start marked but no end yet shows as a single tick, so a half-set loop is still
/// visible rather than silently pending.
private final class LoopBandView: NSView {
    private var start: Double?
    private var end: Double?
    private var duration: Double = 0

    func configure(start: Double?, end: Double?, duration: Double) {
        guard start != self.start || end != self.end || duration != self.duration else { return }
        self.start = start
        self.end = end
        self.duration = duration
        isHidden = start == nil || duration <= 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let start, duration > 0 else { return }
        let startX = position(of: start)
        let endX = end.map(position(of:)) ?? startX
        let band = NSRect(x: startX, y: 0, width: max(2, endX - startX), height: bounds.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: band, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func position(of seconds: Double) -> CGFloat {
        CGFloat(min(max(seconds / duration, 0), 1)) * bounds.width
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
