import AppKit

// The small pieces the player draws over the video, and the payloads its menus carry.

/// Shown when nothing is loaded.
final class PlaceholderView: NSView {
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
final class OSDView: NSVisualEffectView {
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
struct AdjustmentTarget {
    let adjustment: PictureAdjustment
    let value: Int
}

struct AdjustmentNudge {
    let adjustment: PictureAdjustment
    let delta: Int
}

enum MenuSection {
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
