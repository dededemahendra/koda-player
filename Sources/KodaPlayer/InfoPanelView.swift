import AppKit

/// The ⌘I overlay: what mpv actually decided about the file. Codec, bitrate and whether
/// the decode is running on the GPU, refreshed on a timer while the panel is open.
///
/// Rows are rebuilt only when their content changes, so the once-a-second refresh doesn't
/// churn the view hierarchy behind a panel that is mostly sitting still.
final class InfoPanelView: NSVisualEffectView {
    private let stack = NSStackView()
    private var rows: [MediaInfoRow] = []

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        isHidden = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(with newRows: [MediaInfoRow]) {
        guard newRows != rows else { return }
        rows = newRows

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in newRows {
            stack.addArrangedSubview(Self.makeRow(row))
        }
    }

    private static func makeRow(_ row: MediaInfoRow) -> NSView {
        let label = NSTextField(labelWithString: row.label)
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.5)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 108).isActive = true

        let value = NSTextField(labelWithString: row.value)
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        value.textColor = .white
        value.lineBreakMode = .byTruncatingMiddle
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let line = NSStackView(views: [label, value])
        line.spacing = 10
        line.alignment = .firstBaseline
        return line
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
