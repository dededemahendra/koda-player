import AppKit
import UniformTypeIdentifiers

enum TimeFormatter {
    /// `1:02:03` for anything over an hour, `2:03` otherwise. `--:--` for unknown durations.
    static func string(from seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

enum SupportedMedia {
    /// Containers mpv/FFmpeg can demux. Used for the open panel and drag-and-drop filtering;
    /// mpv itself will happily attempt anything, so this list only shapes the UI.
    static let fileExtensions = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "f4v", "mpg", "mpeg",
        "m2v", "mts", "m2ts", "ts", "vob", "ogv", "ogm", "rm", "rmvb", "asf", "divx",
        "3gp", "3g2", "mxf", "y4m", "nut", "amv", "dav", "swf", "gif", "hevc", "h264",
        "av1", "ivf", "mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "wma", "aiff",
        "ape", "dsf", "mka", "tta", "wv"
    ]

    static let subtitleExtensions = ["srt", "ass", "ssa", "sub", "idx", "vtt", "sup", "smi", "txt"]

    static func isPlayable(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    static func isSubtitle(_ url: URL) -> Bool {
        subtitleExtensions.contains(url.pathExtension.lowercased())
    }

    static var openPanelContentTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .audio]
        for ext in fileExtensions + subtitleExtensions {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }
}

/// Remembers where you stopped watching so reopening a file picks up where you left off.
enum ResumeStore {
    private static let key = "resumePositions"
    private static let maximumEntries = 200

    private static var storage: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func save(position: Double, duration: Double, for url: URL) {
        guard duration > 120 else { return }              // don't bother with short clips
        var positions = storage
        let identifier = url.absoluteString
        // Near the start or the end means "watched" — drop the bookmark instead.
        if position < 30 || position > duration - 30 {
            positions.removeValue(forKey: identifier)
        } else {
            positions[identifier] = position
        }
        if positions.count > maximumEntries {
            positions = Dictionary(uniqueKeysWithValues: positions.suffix(maximumEntries))
        }
        storage = positions
    }

    static func position(for url: URL) -> Double? {
        storage[url.absoluteString]
    }
}

/// Settings that outlive a launch.
///
/// Only the ones that describe *you* rather than the file are kept: how loud you like it,
/// how your display is calibrated, whether the window floats. Anything that corrects a
/// particular video — forced aspect, zoom, crop, sync offsets — is deliberately absent,
/// because carrying those into the next file is a bug, not a convenience.
enum Preferences {
    private static let defaults = UserDefaults.standard

    static var volume: Double {
        get { defaults.object(forKey: "volume") as? Double ?? 100 }
        set { defaults.set(max(0, min(130, newValue)), forKey: "volume") }
    }

    static var isMuted: Bool {
        get { defaults.bool(forKey: "muted") }
        set { defaults.set(newValue, forKey: "muted") }
    }

    static var floatOnTop: Bool {
        get { defaults.bool(forKey: "floatOnTop") }
        set { defaults.set(newValue, forKey: "floatOnTop") }
    }

    static func adjustment(_ name: String) -> Int {
        defaults.integer(forKey: "picture.\(name)")
    }

    static func setAdjustment(_ name: String, _ value: Int) {
        defaults.set(value, forKey: "picture.\(name)")
    }
}

/// Recently played files, kept ourselves so the menu works without the document architecture.
enum RecentFiles {
    private static let key = "recentFiles"
    private static let limit = 10

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .compactMap(URL.init(string:))
    }

    static func add(_ url: URL) {
        var identifiers = UserDefaults.standard.stringArray(forKey: key) ?? []
        identifiers.removeAll { $0 == url.absoluteString }
        identifiers.insert(url.absoluteString, at: 0)
        UserDefaults.standard.set(Array(identifiers.prefix(limit)), forKey: key)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
