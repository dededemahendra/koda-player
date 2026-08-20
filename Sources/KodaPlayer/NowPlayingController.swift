import AppKit
import MediaPlayer

/// Two jobs the system expects of a media app, kept together because both are about the
/// Mac's idea of "something is playing right now":
///
/// - the Now Playing panel in Control Center, and the play/pause keys on the keyboard or a
///   pair of headphones, which arrive as remote commands rather than key events;
/// - staying awake, so a film is not interrupted by the display sleeping. Audio-only
///   playback holds the system awake but lets the screen go dark, which is what you want
///   when a record is playing.
final class NowPlayingController {
    enum Command {
        case play
        case pause
        case toggle
        case seek(to: Double)
        case skip(by: Double)
        case next
        case previous
    }

    var onCommand: ((Command) -> Void)?

    private var activity: NSObjectProtocol?
    private var activityAllowsDisplaySleep = true
    private var lastPublished: (title: String, duration: Double, isPaused: Bool, speed: Double)?

    // MARK: - Remote commands

    func start() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in self?.send(.play) ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.send(.pause) ?? .commandFailed }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.send(.toggle) ?? .commandFailed }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.send(.next) ?? .commandFailed }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.send(.previous) ?? .commandFailed }

        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.send(.skip(by: 10)) ?? .commandFailed }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.send(.skip(by: -10)) ?? .commandFailed }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.send(.seek(to: event.positionTime)) ?? .commandFailed
        }
    }

    private func send(_ command: Command) -> MPRemoteCommandHandlerStatus {
        guard let onCommand else { return .noSuchContent }
        // Remote commands do not promise a queue; everything downstream is main-thread.
        if Thread.isMainThread {
            onCommand(command)
        } else {
            DispatchQueue.main.async { onCommand(command) }
        }
        return .success
    }

    // MARK: - Now Playing panel

    /// Republished only when something the panel actually shows has changed. The system
    /// extrapolates the elapsed time from the rate, so a per-frame update would be waste.
    func update(with state: PlaybackState, title: String) {
        let center = MPNowPlayingInfoCenter.default()

        guard state.hasFile else {
            clear()
            return
        }

        let fingerprint = (title, state.duration, state.isPaused, state.speed)
        let changed = lastPublished.map {
            $0.title != fingerprint.0 || $0.duration != fingerprint.1
                || $0.isPaused != fingerprint.2 || $0.speed != fingerprint.3
        } ?? true

        center.playbackState = state.isPaused ? .paused : .playing
        guard changed else { return }
        lastPublished = fingerprint

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPaused ? 0 : state.speed,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
            MPNowPlayingInfoPropertyMediaType: state.hasVideoTrack
                ? MPNowPlayingInfoMediaType.video.rawValue
                : MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if state.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = state.duration
        }
        center.nowPlayingInfo = info
    }

    /// Called on a seek, where the system's extrapolation is suddenly wrong.
    func republishPosition(_ position: Double) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        lastPublished = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - Staying awake

    func updateSleepPrevention(isPlaying: Bool, hasVideo: Bool) {
        guard isPlaying else {
            endActivity()
            return
        }
        // An activity's options are fixed once created, so switching between a video and an
        // audio file has to replace it rather than adjust it.
        if activity != nil, activityAllowsDisplaySleep != !hasVideo { endActivity() }
        guard activity == nil else { return }

        var options: ProcessInfo.ActivityOptions = [.idleSystemSleepDisabled, .userInitiated]
        if hasVideo { options.insert(.idleDisplaySleepDisabled) }
        activity = ProcessInfo.processInfo.beginActivity(
            options: options,
            reason: hasVideo ? "Playing video" : "Playing audio"
        )
        activityAllowsDisplaySleep = !hasVideo
    }

    func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        activityAllowsDisplaySleep = true
    }

    /// Whether the Mac is currently being held awake. Used by the diagnostics dump.
    var isPreventingSleep: Bool { activity != nil }

    deinit {
        endActivity()
    }
}
