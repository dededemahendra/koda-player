import CMPV
import Foundation

/// A single audio / video / subtitle track exposed by mpv.
struct Track: Equatable {
    enum Kind: String {
        case video, audio, sub
    }

    let id: Int
    let kind: Kind
    let title: String?
    let lang: String?
    let codec: String?
    let isSelected: Bool

    /// Human readable label for the track menus.
    var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let lang, !lang.isEmpty, lang != "und" { parts.append("[\(lang)]") }
        if parts.isEmpty, let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if parts.isEmpty { parts.append("Track \(id)") }
        return parts.joined(separator: " ")
    }
}

/// A chapter marker read from the container's chapter list.
struct Chapter: Equatable {
    let index: Int
    let title: String?
    let start: Double

    /// Label for the chapter menus: the title when the file names its chapters, the
    /// number when it doesn't, always with the timestamp.
    var displayName: String {
        let time = TimeFormatter.string(from: start)
        if let title, !title.isEmpty { return "\(title) · \(time)" }
        return "Chapter \(index + 1) · \(time)"
    }
}

/// The aspect ratios offered in the menus. `fromFile` hands the decision back to whatever
/// the container declares, which is right for all but badly authored files.
enum AspectPreset: CaseIterable {
    case fromFile, standard, wide, cinema, scope

    var value: Double {
        switch self {
        case .fromFile: return -1
        case .standard: return 4.0 / 3.0
        case .wide: return 16.0 / 9.0
        case .cinema: return 1.85
        case .scope: return 2.35
        }
    }

    var label: String {
        switch self {
        case .fromFile: return "From File"
        case .standard: return "4:3"
        case .wide: return "16:9"
        case .cinema: return "1.85:1"
        case .scope: return "2.35:1"
        }
    }

    static func matching(_ value: Double) -> AspectPreset? {
        allCases.first { abs($0.value - value) < 0.005 }
    }
}

/// The colour knobs mpv exposes, each running -100…100 with 0 as untouched.
enum PictureAdjustment: String, CaseIterable {
    case brightness, contrast, saturation, gamma

    var label: String { rawValue.capitalized }
}

/// Everything mpv is doing to the picture, mirrored so menus can show what is set.
struct PictureSettings: Equatable {
    /// -1 means "whatever the file says".
    var aspectOverride: Double = -1
    /// mpv's `video-zoom` is log2: 0 fits the window, 1 is twice the size.
    var zoom: Double = 0
    /// 0 letterboxes, 1 crops the picture until it fills the window.
    var panscan: Double = 0
    var brightness = 0
    var contrast = 0
    var saturation = 0
    var gamma = 0

    /// How much bigger than "fit" the picture is drawn, for display as a percentage.
    var zoomScale: Double { pow(2, zoom) }

    var isUntouched: Bool { self == PictureSettings() }

    func value(of adjustment: PictureAdjustment) -> Int {
        switch adjustment {
        case .brightness: return brightness
        case .contrast: return contrast
        case .saturation: return saturation
        case .gamma: return gamma
        }
    }

    mutating func set(_ adjustment: PictureAdjustment, to value: Int) {
        switch adjustment {
        case .brightness: brightness = value
        case .contrast: contrast = value
        case .saturation: saturation = value
        case .gamma: gamma = value
        }
    }
}

/// One line of the media info panel.
struct MediaInfoRow: Equatable {
    let label: String
    let value: String
}

/// Everything the UI needs to draw itself, kept in sync from mpv's property observers.
struct PlaybackState {
    var hasFile = false
    var isPaused = true
    var isBuffering = false
    var position: Double = 0
    var duration: Double = 0
    var volume: Double = 100
    var isMuted = false
    var speed: Double = 1
    var mediaTitle = ""
    var videoWidth = 0
    var videoHeight = 0
    var tracks: [Track] = []
    var chapters: [Chapter] = []
    /// mpv's chapter index, or -1 for a file without chapters.
    var currentChapter = -1
    var loopStart: Double?
    var loopEnd: Double?
    var subtitleDelay: Double = 0
    var audioDelay: Double = 0
    var picture = PictureSettings()
    var isLoopingFile = false

    var hasLoop: Bool {
        loopStart != nil
    }

    var aspectRatio: Double {
        guard videoWidth > 0, videoHeight > 0 else { return 16.0 / 9.0 }
        return Double(videoWidth) / Double(videoHeight)
    }

    var hasVideoTrack: Bool {
        videoWidth > 0 && videoHeight > 0
    }

    func tracks(of kind: Track.Kind) -> [Track] {
        tracks.filter { $0.kind == kind }
    }

    func selectedTrack(of kind: Track.Kind) -> Track? {
        tracks.first { $0.kind == kind && $0.isSelected }
    }
}

protocol MPVPlayerDelegate: AnyObject {
    func playerStateDidChange(_ player: MPVPlayer)
    func playerDidLoadFile(_ player: MPVPlayer)
    func playerDidEndFile(_ player: MPVPlayer, reason: MPVPlayer.EndReason)
}

/// Thin Swift wrapper around libmpv.
///
/// mpv does all demuxing and decoding, which is what buys us "plays literally anything"
/// without writing a single codec. Frames are handed to `MPVVideoView` through the
/// libmpv render API (`vo=libmpv`) rather than mpv opening a window of its own, because
/// `--wid` embedding is not supported on macOS.
final class MPVPlayer {
    enum EndReason {
        case finished
        case stopped
        case error(String)
    }

    weak var delegate: MPVPlayerDelegate?
    private(set) var state = PlaybackState()

    /// Exposed so the video view can build a render context against the same instance.
    private(set) var handle: OpaquePointer?

    private let eventQueue = DispatchQueue(label: "com.koda.player.events", qos: .userInitiated)
    private var isShuttingDown = false
    /// Guards against reporting the end of the same file twice (eof-reached toggles).
    private var didReportEndOfFile = false

    // MARK: - Lifecycle

    init() {
        guard let handle = mpv_create() else {
            fatalError("mpv_create() failed: libmpv could not be initialised")
        }
        self.handle = handle

        // We render into our own OpenGL view and draw the entire UI ourselves.
        setOption("vo", "libmpv")
        setOption("osc", "no")
        setOption("osd-level", "0")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("input-cursor", "no")
        setOption("config", "no")          // ignore ~/.config/mpv so behaviour is predictable
        setOption("terminal", "no")
        setOption("ytdl", "no")

        // Playback behaviour.
        setOption("idle", "yes")           // stay alive with no file loaded
        setOption("keep-open", "yes")      // pause on the last frame instead of unloading
        setOption("hwdec", "videotoolbox") // hardware decode, silently falls back to software
        setOption("audio-display", "no")
        setOption("sub-auto", "fuzzy")     // pick up sidecar .srt files sitting next to the video
        setOption("audio-file-auto", "fuzzy")
        setOption("volume-max", "130")
        setOption("cache", "yes")
        setOption("demuxer-max-bytes", "64MiB")
        setOption("screenshot-directory", NSHomeDirectory() + "/Desktop")
        setOption("screenshot-format", "png")

        guard mpv_initialize(handle) >= 0 else {
            fatalError("mpv_initialize() failed")
        }

        observeProperties()
        startEventLoop()
    }

    deinit {
        shutdown()
    }

    /// Asks mpv to quit. The event thread owns the handle and destroys it when the
    /// resulting MPV_EVENT_SHUTDOWN arrives, so nothing is torn down mid-`mpv_wait_event`.
    func shutdown() {
        guard let handle, !isShuttingDown else { return }
        isShuttingDown = true
        mpv_command_string(handle, "quit")
    }

    // MARK: - Playback control

    func open(url: URL) {
        didReportEndOfFile = false
        clearLoop()
        resetSync()
        resetPictureGeometry()
        command(["loadfile", url.isFileURL ? url.path : url.absoluteString])
        state.hasFile = true
        setPaused(false)
    }

    func togglePause() {
        guard state.hasFile else { return }
        setPaused(!state.isPaused)
    }

    func setPaused(_ paused: Bool) {
        setFlag("pause", paused)
    }

    func stop() {
        command(["stop"])
        // Volume, mute, the colour adjustments and the repeat mode belong to mpv rather
        // than to the file, and stopping does not change them, so they survive the reset.
        var cleared = PlaybackState()
        cleared.volume = state.volume
        cleared.isMuted = state.isMuted
        cleared.picture = state.picture
        cleared.picture.aspectOverride = -1
        cleared.picture.zoom = 0
        cleared.picture.panscan = 0
        cleared.isLoopingFile = state.isLoopingFile
        state = cleared
        notifyStateChanged()
    }

    /// Relative seek in seconds. Keyframe seeking keeps scrubbing responsive on big files.
    func seek(by seconds: Double, exact: Bool = false) {
        guard state.hasFile else { return }
        command(["seek", String(seconds), "relative", exact ? "exact" : "keyframes"])
    }

    func seek(to seconds: Double, exact: Bool = true) {
        guard state.hasFile else { return }
        let upperBound = state.duration > 0 ? state.duration : seconds
        let clamped = max(0, min(seconds, upperBound))
        command(["seek", String(clamped), "absolute", exact ? "exact" : "keyframes"])
    }

    func step(frames: Int) {
        guard state.hasFile else { return }
        command([frames > 0 ? "frame-step" : "frame-back-step"])
    }

    func setVolume(_ volume: Double) {
        setDouble("volume", max(0, min(130, volume)))
    }

    func adjustVolume(by delta: Double) {
        setVolume(state.volume + delta)
    }

    func toggleMute() {
        setFlag("mute", !state.isMuted)
    }

    func setSpeed(_ speed: Double) {
        setDouble("speed", max(0.25, min(4, speed)))
    }

    func selectTrack(_ track: Track?, kind: Track.Kind) {
        let property: String
        switch kind {
        case .video: property = "vid"
        case .audio: property = "aid"
        case .sub: property = "sid"
        }
        setString(property, track.map { String($0.id) } ?? "no")
        refreshTracks()
        notifyStateChanged()
    }

    func cycleSubtitles() {
        command(["cycle", "sub"])
        refreshTracks()
        notifyStateChanged()
    }

    func addSubtitleFile(_ url: URL) {
        command(["sub-add", url.path, "select"])
        refreshTracks()
        notifyStateChanged()
    }

    func takeScreenshot() {
        command(["screenshot"])
    }

    /// mpv's `loop-file`, which repeats the current file until you turn it off. Returns
    /// the mode it landed in.
    @discardableResult
    func toggleLoopFile() -> Bool {
        let looping = !state.isLoopingFile
        setString("loop-file", looping ? "inf" : "no")
        state.isLoopingFile = looping
        notifyStateChanged()
        return looping
    }

    // MARK: - Chapters

    /// Reads the chapter list through indexed properties, the same way tracks are read.
    func refreshChapters() {
        guard let count = getInt("chapter-list/count"), count > 0 else {
            state.chapters = []
            state.currentChapter = -1
            return
        }
        state.chapters = (0..<count).map { index in
            Chapter(
                index: index,
                title: getString("chapter-list/\(index)/title"),
                start: getDouble("chapter-list/\(index)/time") ?? 0
            )
        }
        state.currentChapter = getInt("chapter") ?? -1
    }

    func seekToChapter(_ index: Int) {
        guard state.chapters.indices.contains(index) else { return }
        setInt("chapter", index)
    }

    /// Moves `offset` chapters from wherever playback is now. Returns the chapter it moved
    /// to, or nil when there is nothing in that direction.
    @discardableResult
    func stepChapter(by offset: Int) -> Chapter? {
        guard !state.chapters.isEmpty else { return nil }
        let target = (getInt("chapter") ?? state.currentChapter) + offset
        guard state.chapters.indices.contains(target) else { return nil }
        seekToChapter(target)
        return state.chapters[target]
    }

    // MARK: - A-B loop

    enum LoopChange {
        case start(Double)
        case range(Double, Double)
        case cleared
    }

    /// Cycles mpv's `ab-loop-a` / `ab-loop-b`: mark the start, mark the end, then clear.
    /// An end marked before the start swaps the two rather than refusing, and a range too
    /// short to hear is treated as a cancelled loop.
    @discardableResult
    func cycleLoopPoint() -> LoopChange {
        guard state.hasFile else { return .cleared }

        guard let start = state.loopStart else {
            let position = state.position
            setDouble("ab-loop-a", position)
            state.loopStart = position
            notifyStateChanged()
            return .start(position)
        }
        guard state.loopEnd == nil else {
            clearLoop()
            return .cleared
        }

        let bounds = [start, state.position].sorted()
        guard bounds[1] - bounds[0] >= 0.5 else {
            clearLoop()
            return .cleared
        }
        setDouble("ab-loop-a", bounds[0])
        setDouble("ab-loop-b", bounds[1])
        state.loopStart = bounds[0]
        state.loopEnd = bounds[1]
        notifyStateChanged()
        return .range(bounds[0], bounds[1])
    }

    func clearLoop() {
        setString("ab-loop-a", "no")
        setString("ab-loop-b", "no")
        state.loopStart = nil
        state.loopEnd = nil
        notifyStateChanged()
    }

    // MARK: - Audio and subtitle sync

    /// Nudges the subtitle delay and returns the value that landed. Rounded so repeated
    /// 0.1s steps don't drift into 0.30000000000000004.
    @discardableResult
    func adjustSubtitleDelay(by delta: Double) -> Double {
        let value = Self.rounded(state.subtitleDelay + delta)
        setDouble("sub-delay", value)
        state.subtitleDelay = value
        notifyStateChanged()
        return value
    }

    @discardableResult
    func adjustAudioDelay(by delta: Double) -> Double {
        let value = Self.rounded(state.audioDelay + delta)
        setDouble("audio-delay", value)
        state.audioDelay = value
        notifyStateChanged()
        return value
    }

    /// Both delays are mpv-wide rather than per-file, so every `open` clears them: a
    /// correction made for one video should not silently follow you into the next.
    func resetSync() {
        setDouble("sub-delay", 0)
        setDouble("audio-delay", 0)
        state.subtitleDelay = 0
        state.audioDelay = 0
        notifyStateChanged()
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    // MARK: - Picture

    func setAspectOverride(_ value: Double) {
        setDouble("video-aspect-override", value)
        state.picture.aspectOverride = value
        notifyStateChanged()
    }

    /// Walks the preset list, starting over once past the end. An override that matches no
    /// preset (nothing sets one today, but mpv would allow it) restarts at the first.
    @discardableResult
    func cycleAspectOverride() -> AspectPreset {
        let current = AspectPreset.matching(state.picture.aspectOverride) ?? .fromFile
        let index = AspectPreset.allCases.firstIndex(of: current) ?? 0
        let next = AspectPreset.allCases[(index + 1) % AspectPreset.allCases.count]
        setAspectOverride(next.value)
        return next
    }

    /// Zoom is clamped to half size … four times size; beyond that the picture is unusable
    /// and mpv will happily let you get lost.
    @discardableResult
    func adjustZoom(by delta: Double) -> Double {
        let value = max(-1, min(2, Self.rounded(state.picture.zoom + delta)))
        setDouble("video-zoom", value)
        state.picture.zoom = value
        notifyStateChanged()
        return value
    }

    @discardableResult
    func adjustPanscan(by delta: Double) -> Double {
        let value = max(0, min(1, Self.rounded(state.picture.panscan + delta)))
        setDouble("panscan", value)
        state.picture.panscan = value
        notifyStateChanged()
        return value
    }

    func setPanscan(_ value: Double) {
        let clamped = max(0, min(1, value))
        setDouble("panscan", clamped)
        state.picture.panscan = clamped
        notifyStateChanged()
    }

    @discardableResult
    func setAdjustment(_ adjustment: PictureAdjustment, to value: Int) -> Int {
        let clamped = max(-100, min(100, value))
        setInt(adjustment.rawValue, clamped)
        state.picture.set(adjustment, to: clamped)
        notifyStateChanged()
        return clamped
    }

    @discardableResult
    func adjust(_ adjustment: PictureAdjustment, by delta: Int) -> Int {
        setAdjustment(adjustment, to: state.picture.value(of: adjustment) + delta)
    }

    /// Frames the picture as the file intends. Called for every new file: a zoom or a
    /// forced aspect is a fix for one video, never a preference.
    func resetPictureGeometry() {
        setDouble("video-aspect-override", -1)
        setDouble("video-zoom", 0)
        setDouble("panscan", 0)
        state.picture.aspectOverride = -1
        state.picture.zoom = 0
        state.picture.panscan = 0
        notifyStateChanged()
    }

    /// Also drops the colour adjustments, which otherwise persist across files because
    /// they usually describe the display rather than the video.
    func resetPicture() {
        resetPictureGeometry()
        for adjustment in PictureAdjustment.allCases {
            setInt(adjustment.rawValue, 0)
            state.picture.set(adjustment, to: 0)
        }
        notifyStateChanged()
    }

    // MARK: - Media info

    /// Reads what mpv knows about the file right now. Built on demand rather than observed:
    /// the panel is usually closed, and half of these only settle once decoding is underway.
    func mediaInfo() -> [MediaInfoRow] {
        var rows: [MediaInfoRow] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty, value != "0" else { return }
            rows.append(MediaInfoRow(label: label, value: value))
        }

        add("File", getString("filename"))
        // mpv names the demuxer, not the container: "mov,mp4,m4a,3gp,3g2,mj2" for an MP4.
        // The first entry is the one worth showing.
        add("Format", getString("file-format")?.split(separator: ",").first.map { $0.uppercased() })
        add("Size", getInt("file-size").map(Self.fileSize))
        add("Duration", state.duration > 0 ? TimeFormatter.string(from: state.duration) : nil)

        if state.hasVideoTrack {
            add("Video", getString("video-codec"))
            add("Resolution", "\(state.videoWidth) × \(state.videoHeight)")
            let fps = getDouble("estimated-vf-fps") ?? getDouble("container-fps")
            add("Frame rate", fps.map { String(format: "%.2f fps", $0) })
            add("Video bitrate", getDouble("video-bitrate").map(Self.bitrate))
            add("Hardware decoding", getString("hwdec-current").map { $0 == "no" ? "Software" : $0 })
            add("Dropped frames", getInt("frame-drop-count").map(String.init))
        }

        if let audio = state.selectedTrack(of: .audio) {
            add("Audio", getString("audio-codec-name")?.uppercased() ?? audio.codec)
            let channels = getInt("audio-params/channel-count")
            let rate = getInt("audio-params/samplerate")
            if let channels, let rate {
                add("Audio format", "\(channels) ch · \(rate / 1000) kHz")
            }
            add("Audio bitrate", getDouble("audio-bitrate").map(Self.bitrate))
        }

        add("Cache", getDouble("demuxer-cache-duration").map { String(format: "%.1fs buffered", $0) })
        return rows
    }

    private static func bitrate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kbps", bitsPerSecond / 1_000)
    }

    private static func fileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Property plumbing

    private func setOption(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_option_string(handle, name, value)
    }

    private func setString(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var flag = Int32(value ? 1 : 0)
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
    }

    private func setInt(_ name: String, _ value: Int) {
        guard let handle else { return }
        var v = Int64(value)
        mpv_set_property(handle, name, MPV_FORMAT_INT64, &v)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let handle else { return }
        var v = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
    }

    private func getDouble(_ name: String) -> Double? {
        guard let handle else { return nil }
        var v: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v) >= 0 else { return nil }
        return v
    }

    private func getInt(_ name: String) -> Int? {
        guard let handle else { return nil }
        var v: Int64 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &v) >= 0 else { return nil }
        return Int(v)
    }

    private func getString(_ name: String) -> String? {
        guard let handle, let cString = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    private func command(_ args: [String]) {
        guard let handle else { return }
        // mpv_command takes a NULL-terminated `const char **`.
        var cArgs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cArgs.append(nil)
        defer {
            cArgs.forEach { pointer in
                if let pointer { free(UnsafeMutableRawPointer(mutating: pointer)) }
            }
        }
        mpv_command(handle, &cArgs)
    }

    private func observeProperties() {
        guard let handle else { return }
        for name in ["time-pos", "duration", "volume", "speed", "sub-delay", "audio-delay",
                     "video-zoom", "panscan", "video-aspect-override"] {
            mpv_observe_property(handle, 0, name, MPV_FORMAT_DOUBLE)
        }
        // `eof-reached` matters because keep-open=yes parks on the last frame instead of
        // unloading, so MPV_EVENT_END_FILE never arrives at the natural end of a file.
        for name in ["pause", "mute", "paused-for-cache", "eof-reached"] {
            mpv_observe_property(handle, 0, name, MPV_FORMAT_FLAG)
        }
        for name in ["media-title"] {
            mpv_observe_property(handle, 0, name, MPV_FORMAT_STRING)
        }
        for name in ["track-list/count", "chapter-list/count", "chapter", "dwidth", "dheight",
                     "brightness", "contrast", "saturation", "gamma"] {
            mpv_observe_property(handle, 0, name, MPV_FORMAT_INT64)
        }
    }

    /// mpv's event payload is only valid until the next `mpv_wait_event`, so every event is
    /// decoded into plain Swift values here and then applied on the main thread.
    private func startEventLoop() {
        eventQueue.async { [weak self] in
            while true {
                guard let self, let handle = self.handle, !self.isShuttingDown else { return }
                guard let eventPointer = mpv_wait_event(handle, 0.05) else { continue }
                let event = eventPointer.pointee

                switch event.event_id {
                case MPV_EVENT_SHUTDOWN:
                    self.handle = nil
                    mpv_terminate_destroy(handle)
                    return

                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let raw = event.data?.assumingMemoryBound(to: mpv_event_property.self) else { break }
                    let name = String(cString: raw.pointee.name)
                    let update = Self.decode(property: raw.pointee)
                    DispatchQueue.main.async { self.apply(update: update, name: name) }

                case MPV_EVENT_FILE_LOADED:
                    DispatchQueue.main.async {
                        self.state.hasFile = true
                        self.didReportEndOfFile = false
                        self.refreshTracks()
                        self.refreshChapters()
                        self.refreshVideoSize()
                        self.delegate?.playerDidLoadFile(self)
                        self.notifyStateChanged()
                    }

                case MPV_EVENT_END_FILE:
                    let reason: EndReason
                    if let raw = event.data?.assumingMemoryBound(to: mpv_event_end_file.self) {
                        switch raw.pointee.reason {
                        case MPV_END_FILE_REASON_EOF:
                            reason = .finished
                        case MPV_END_FILE_REASON_ERROR:
                            reason = .error(String(cString: mpv_error_string(raw.pointee.error)))
                        default:
                            reason = .stopped
                        }
                    } else {
                        reason = .stopped
                    }
                    DispatchQueue.main.async { self.delegate?.playerDidEndFile(self, reason: reason) }

                default:
                    break
                }
            }
        }
    }

    private enum PropertyUpdate {
        case double(Double)
        case flag(Bool)
        case int(Int)
        case string(String)
        case none
    }

    private static func decode(property: mpv_event_property) -> PropertyUpdate {
        guard let data = property.data else { return .none }
        switch property.format {
        case MPV_FORMAT_DOUBLE:
            return .double(data.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_FLAG:
            return .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case MPV_FORMAT_INT64:
            return .int(Int(data.assumingMemoryBound(to: Int64.self).pointee))
        case MPV_FORMAT_STRING:
            let pointer = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
            return .string(pointer.map { String(cString: $0) } ?? "")
        default:
            return .none
        }
    }

    private func apply(update: PropertyUpdate, name: String) {
        switch (name, update) {
        case ("time-pos", .double(let value)): state.position = value
        case ("duration", .double(let value)): state.duration = value
        case ("volume", .double(let value)): state.volume = value
        case ("speed", .double(let value)): state.speed = value
        case ("pause", .flag(let value)): state.isPaused = value
        case ("mute", .flag(let value)): state.isMuted = value
        case ("paused-for-cache", .flag(let value)): state.isBuffering = value
        case ("media-title", .string(let value)): state.mediaTitle = value
        case ("eof-reached", .flag(let reachedEnd)):
            guard reachedEnd, !didReportEndOfFile else { return }
            didReportEndOfFile = true
            delegate?.playerDidEndFile(self, reason: .finished)
            return
        case ("sub-delay", .double(let value)): state.subtitleDelay = value
        case ("audio-delay", .double(let value)): state.audioDelay = value
        case ("track-list/count", .int): refreshTracks()
        case ("chapter-list/count", .int): refreshChapters()
        case ("chapter", .int(let value)): state.currentChapter = value
        case ("video-zoom", .double(let value)): state.picture.zoom = value
        case ("panscan", .double(let value)): state.picture.panscan = value
        case ("video-aspect-override", .double(let value)): state.picture.aspectOverride = value
        case (PictureAdjustment.brightness.rawValue, .int(let value)): state.picture.brightness = value
        case (PictureAdjustment.contrast.rawValue, .int(let value)): state.picture.contrast = value
        case (PictureAdjustment.saturation.rawValue, .int(let value)): state.picture.saturation = value
        case (PictureAdjustment.gamma.rawValue, .int(let value)): state.picture.gamma = value
        case ("dwidth", .int(let value)): state.videoWidth = value
        case ("dheight", .int(let value)): state.videoHeight = value
        default: return
        }
        notifyStateChanged()
    }

    private func refreshVideoSize() {
        state.videoWidth = getInt("dwidth") ?? state.videoWidth
        state.videoHeight = getInt("dheight") ?? state.videoHeight
    }

    /// Reads the track list through indexed properties, which is much less code than
    /// decoding an mpv node tree.
    func refreshTracks() {
        guard let count = getInt("track-list/count"), count > 0 else {
            state.tracks = []
            return
        }
        var tracks: [Track] = []
        for index in 0..<count {
            guard let typeString = getString("track-list/\(index)/type"),
                  let kind = Track.Kind(rawValue: typeString),
                  let id = getInt("track-list/\(index)/id") else { continue }
            tracks.append(
                Track(
                    id: id,
                    kind: kind,
                    title: getString("track-list/\(index)/title"),
                    lang: getString("track-list/\(index)/lang"),
                    codec: getString("track-list/\(index)/codec"),
                    isSelected: getString("track-list/\(index)/selected") == "yes"
                )
            )
        }
        state.tracks = tracks
    }

    private func notifyStateChanged() {
        delegate?.playerStateDidChange(self)
    }
}
