import AppKit

/// A compact drag destination. Explicit tiles make the result of a drop predictable.
/// The main window provides the same actions through keyboard-accessible controls.
final class BubbleArcView: NSView {
    var onDrop: ((PickerItem, [URL]) -> Void)?
    override var isFlipped: Bool { true }
    private var items: [PickerItem] = []
    private var urls: [URL] = []
    private var isTools = false
    private var hovered: Int? { didSet { needsDisplay = true } }

    var preferredSize: NSSize {
        NSSize(width: 360, height: 68 + CGFloat(max(1, (items.count + 2) / 3)) * 72 + 44)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel(L("FileFlipper quick actions"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items: [PickerItem], urls: [URL], tools: Bool) {
        self.items = items
        self.urls = urls
        self.isTools = tools
        hovered = nil
        needsDisplay = true
    }

    // Kept internal so geometry can be checked without an OS drag session.
    func tileRect(at index: Int) -> NSRect {
        let width = (bounds.width - 48) / 3
        return NSRect(x: 16 + CGFloat(index % 3) * (width + 8),
                      y: 68 + CGFloat(index / 3) * 72, width: width, height: 64)
    }
    func itemIndex(at point: NSPoint) -> Int? {
        items.indices.first { tileRect(at: $0).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.surface.setFill()
        let surface = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        surface.fill()
        Palette.border.setStroke(); surface.lineWidth = 1; surface.stroke()
        text(isTools ? L("Quick tools") : L("Convert formats"),
             rect: NSRect(x: 16, y: 14, width: bounds.width - 32, height: 18), size: 13, weight: .semibold)
        let name = urls.count == 1 ? (urls.first?.lastPathComponent ?? "") : L("%@ files", String(urls.count))
        text(name, rect: NSRect(x: 16, y: 37, width: bounds.width - 32, height: 17), size: 11, color: Palette.secondary)
        if items.isEmpty {
            text(L("Open FileFlipper to choose compatible files."),
                 rect: NSRect(x: 20, y: 83, width: bounds.width - 40, height: 40), size: 12, color: Palette.secondary, centered: true)
        }
        for index in items.indices {
            let item = items[index]
            let rect = tileRect(at: index)
            let active = hovered == index
            let tile = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            (active ? Palette.accent : Palette.control).setFill(); tile.fill()
            if !active { Palette.border.withAlphaComponent(0.5).setStroke(); tile.lineWidth = 0.5; tile.stroke() }
            let color = active ? NSColor.white : Palette.text
            let icon = NSImage(systemSymbolName: item.symbol ?? Catalog.formatSymbol(for: item.title), accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
            if let icon {
                let size = icon.size
                icon.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.minY + 9, width: size.width, height: size.height),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            text(item.title, rect: NSRect(x: rect.minX + 4, y: rect.minY + 40, width: rect.width - 8, height: 18),
                 size: 12, weight: .medium, color: color, centered: true)
        }
        let hint = hovered.map { items[$0].detail ?? L("Save as %@", items[$0].title) } ?? L("Drop on an option · Release outside to cancel")
        text(hint, rect: NSRect(x: 16, y: bounds.height - 30, width: bounds.width - 32, height: 17),
             size: 11, color: Palette.secondary, centered: true)
    }

    private func text(_ value: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, centered: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = centered ? .center : .left
        style.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: style]).draw(in: rect)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hovered != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = itemIndex(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let item = items[index]
        let dropped = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let targets = dropped.isEmpty ? urls : dropped
        hovered = nil
        DispatchQueue.main.async { [weak self] in self?.onDrop?(item, targets) }
        return true
    }
    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovered = itemIndex(at: convert(sender.draggingLocation, from: nil))
        return hovered == nil ? [] : .copy
    }
}
