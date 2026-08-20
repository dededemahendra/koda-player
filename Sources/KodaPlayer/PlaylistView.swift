import AppKit

protocol PlaylistViewDelegate: AnyObject {
    /// A row was chosen. The queue itself must not be rebuilt in response.
    func playlistDidChoose(_ url: URL)
    /// The queue was reordered or had rows removed; this is the whole new order.
    func playlistDidChange(to urls: [URL])
    /// Files were dropped onto the panel, to be appended rather than to replace the queue.
    func playlistDidReceive(_ urls: [URL])
}

/// The queue, as a panel over the right-hand edge of the video.
///
/// It shows what will play next and lets you say otherwise: drag rows to reorder, drag
/// files in to add them, `⌫` to remove. Choosing a row plays it without reseeding the
/// queue from that file's folder, which is what separates a queue from the plain
/// folder-walk the player did before.
final class PlaylistView: NSVisualEffectView {
    weak var delegate: PlaylistViewDelegate?

    private(set) var items: [URL] = []
    private var currentURL: URL?

    private let tableView = PlaylistTableView()
    private let scrollView = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "Up Next")
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Drop files here")

    private static let rowType = NSPasteboard.PasteboardType("com.koda.playlist.row")

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        isHidden = true

        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func buildLayout() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.45)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, NSView(), countLabel])
        header.spacing = 8
        header.alignment = .firstBaseline

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(playSelectedRow)
        tableView.onDeleteKey = { [weak self] in self?.removeSelectedRows() }
        tableView.onPlayKey = { [weak self] in self?.playSelectedRow() }
        tableView.registerForDraggedTypes([Self.rowType, .fileURL])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [header, scrollView])
        root.orientation = .vertical
        root.spacing = 8
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    // MARK: - Contents

    func update(items: [URL], current: URL?) {
        guard items != self.items || current != currentURL else { return }
        self.items = items
        currentURL = current
        countLabel.stringValue = items.isEmpty ? "" : "\(items.count)"
        emptyLabel.isHidden = !items.isEmpty
        tableView.reloadData()

        if let current, let row = items.firstIndex(of: current) {
            tableView.scrollRowToVisible(row)
        }
    }

    @objc private func playSelectedRow() {
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { return }
        delegate?.playlistDidChoose(items[row])
    }

    private func removeSelectedRows() {
        let selected = tableView.selectedRowIndexes
        guard !selected.isEmpty else { return }
        var remaining = items
        for index in selected.sorted(by: >) { remaining.remove(at: index) }
        delegate?.playlistDidChange(to: remaining)
    }
}

// MARK: - Table data

extension PlaylistView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = items[row]
        let isPlaying = url == currentURL

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.font = .systemFont(ofSize: 12, weight: isPlaying ? .semibold : .regular)
        label.textColor = isPlaying ? .controlAccentColor : NSColor.white.withAlphaComponent(0.85)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.toolTip = url.path

        let marker = NSImageView()
        marker.image = isPlaying ? ControlsView.symbolImage("speaker.wave.2.fill", size: 10) : nil
        marker.contentTintColor = .controlAccentColor
        marker.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(marker)
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            marker.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    // MARK: Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard operation == .above else { return [] }
        return isLocalReorder(info) ? .move : .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation operation: NSTableView.DropOperation
    ) -> Bool {
        if isLocalReorder(info) {
            let moved = draggedRows(from: info)
            guard !moved.isEmpty else { return false }
            delegate?.playlistDidChange(to: Self.reordering(items, moving: moved, to: row))
            return true
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let dropped = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        let playable = dropped.filter { SupportedMedia.isPlayable($0) }
        guard !playable.isEmpty else { return false }
        delegate?.playlistDidReceive(playable)
        return true
    }

    /// Drops land *above* a row, and the rows being moved are removed first, so every
    /// dragged row that sat above the drop point shifts the insertion index down by one.
    /// Kept separate from the drag plumbing because this is the part that can be wrong.
    static func reordering(_ items: [URL], moving rows: [Int], to destination: Int) -> [URL] {
        let valid = rows.filter { items.indices.contains($0) }.sorted()
        guard !valid.isEmpty else { return items }

        let lifted = valid.map { items[$0] }
        var remaining = items
        for index in valid.reversed() { remaining.remove(at: index) }

        let insertion = destination - valid.filter { $0 < destination }.count
        remaining.insert(contentsOf: lifted, at: max(0, min(insertion, remaining.count)))
        return remaining
    }

    private func isLocalReorder(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? NSTableView) === tableView
    }

    private func draggedRows(from info: NSDraggingInfo) -> [Int] {
        (info.draggingPasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: Self.rowType) }
            .compactMap(Int.init)
            .sorted()
    }
}

/// Adds the two keys a list is expected to answer to.
private final class PlaylistTableView: NSTableView {
    var onDeleteKey: (() -> Void)?
    var onPlayKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:            // delete, forward delete
            onDeleteKey?()
        case 36, 76:             // return, enter
            onPlayKey?()
        default:
            super.keyDown(with: event)
        }
    }
}
