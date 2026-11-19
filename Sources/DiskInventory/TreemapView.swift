import AppKit
import InventoryCore

@MainActor final class TreemapView: NSView {
    var choose: ((Int, Bool) -> Void)?
    var zoomAggregate: ((Int) -> Void)?
    var hover: ((Int?) -> Void)?
    var context: ((Int) -> NSMenu?)?
    var acceptsTileActions = false
    private var tracking: NSTrackingArea?
    private var tiles: [MapTile] = []
    var hasTiles: Bool { !tiles.isEmpty }
    private var colors: [CGColor] = []
    func usesAnySwatch(from swatches: [NSColor]) -> Bool {
        let expected = swatches.map(\.cgColor)
        return colors.contains { expected.contains($0) }
    }

    private var labelColors: [NSColor] = []
    var mapAppearance = MapAppearance() {
        didSet { if oldValue != mapAppearance { needsDisplay = true } }
    }
    private var labels: [Int: String] = [:]
    private var nodeKinds: [Int32] = []
    private var tileSize: CGSize = .zero
    private var selectionFrames: [Int: CGRect] = [:]
    private var hoverID: Int?
    private let highlight = SelectionHighlight()
    var selection: Int? { didSet { if oldValue != selection { updateHighlight() } } }
    var resized: (() -> Void)?
    var message = "Open a folder or volume to scan." { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleAxesIndependently
        highlight.frame = bounds
        highlight.autoresizingMask = [.width, .height]
        highlight.wantsLayer = true
        addSubview(highlight)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Disk usage treemap. The file tree contains the same items.")
    }

    required init?(coder: NSCoder) { nil }

    func show(_ tiles: [MapTile], snapshot: ScanSummary, colors: [NSColor], size: CGSize, animate: Bool) {
        self.tiles = tiles
        acceptsTileActions = true
        tileSize = size
        recolor(colors)
        labels.removeAll(keepingCapacity: true)
        nodeKinds = tiles.map { $0.id >= 0 ? snapshot.nodes[$0.id].kind : -1 }
        for tile in tiles where tile.rect.width > 84 && tile.rect.height > 22 && !tile.container {
            labels[tile.id] = tile.id >= 0 ? snapshot.nodes[tile.id].name : (tile.id == -1 ? "Free Space" : "Other Space")
        }
        selectionFrames.removeAll(keepingCapacity: true)
        for tile in tiles where !tile.aggregate {
            selectionFrames[tile.id] = tile.rect
        }
        hoverID = nil
        updateHighlight()
        if animate {
            let fade = CATransition()
            fade.duration = 0.17
            fade.type = .fade
            layer?.add(fade, forKey: "zoom")
        }
        needsDisplay = true
    }

    func recolor(_ colors: [NSColor]) {
        self.colors = colors.map { $0.cgColor }
        labelColors = colors.map(TreemapPalette.foreground)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        highlight.needsDisplay = true
    }

    func clear() {
        acceptsTileActions = false
        tiles = []
        nodeKinds = []
        labels = [:]
        selectionFrames = [:]
        hoverID = nil
        updateHighlight()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previous = frame.size
        super.setFrameSize(newSize)
        if newSize != previous {
            updateHighlight()
            if tiles.isEmpty { needsDisplay = true }
            resized?()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func tile(at event: NSEvent) -> MapTile? {
        guard acceptsTileActions, bounds.width > 0, bounds.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let original = CGPoint(x: point.x * tileSize.width / bounds.width, y: point.y * tileSize.height / bounds.height)
        return tiles.last(where: { $0.rect.contains(original) })
    }

    override func mouseMoved(with event: NSEvent) {
        let tile = tile(at: event)
        let id = tile?.aggregate == false ? tile?.id : nil
        guard id != hoverID else { return }
        hoverID = id
        hover?(id)
    }

    override func mouseExited(with event: NSEvent) {
        hoverID = nil
        hover?(nil)
    }

    private func updateHighlight() {
        guard let selection, let rect = selectionFrames[selection], tileSize.width > 0, tileSize.height > 0 else {
            highlight.rectangle = nil
            return
        }
        let transform = CGAffineTransform(scaleX: bounds.width / tileSize.width, y: bounds.height / tileSize.height)
        highlight.rectangle = rect.applying(transform).insetBy(dx: 0.35, dy: 0.35)
    }

    override func mouseDown(with event: NSEvent) {
        guard let tile = tile(at: event) else { return }
        if tile.aggregate {
            if event.clickCount == 2 { zoomAggregate?(tile.id) }
        } else {
            choose?(tile.id, event.clickCount == 2)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tile = tile(at: event), !tile.aggregate else { return nil }
        return context?(tile.id)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        guard !tiles.isEmpty, tileSize.width > 0, tileSize.height > 0,
              let graphics = NSGraphicsContext.current else {
            let text = NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: max(8, (bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2))
            return
        }
        let context = graphics.cgContext
        graphics.saveGraphicsState()
        context.scaleBy(x: bounds.width / tileSize.width, y: bounds.height / tileSize.height)
        let group = NSColor.secondaryLabelColor.withAlphaComponent(0.38).cgColor
        let aggregate = NSColor.tertiaryLabelColor.withAlphaComponent(0.65).cgColor
        let space = NSColor.secondaryLabelColor.withAlphaComponent(0.62).cgColor
        let line = NSColor.black.withAlphaComponent(0.17).cgColor
        let folderBorder = NSColor.windowBackgroundColor.cgColor
        for (index, tile) in tiles.enumerated() {
            let kind = Int(nodeKinds[index])
            let color = tile.aggregate ? aggregate : tile.container ? group : kind < 0 ? space : colors[kind]
            context.setFillColor(color)
            let frame = tile.rect.insetBy(dx: 0.35, dy: 0.35)
            guard frame.width > 0, frame.height > 0 else { continue }
            context.fill(frame)
            if tile.container && mapAppearance.folderBorders {
                context.setStrokeColor(folderBorder)
                context.setLineWidth(1.5)
                context.stroke(frame.insetBy(dx: 0.75, dy: 0.75))
            } else if !tile.container && !tile.aggregate {
                context.setStrokeColor(line)
                context.setLineWidth(0.65)
                context.stroke(frame.insetBy(dx: 0.4, dy: 0.4))
            }
            if mapAppearance.labels, frame.width >= 70, frame.height >= 20, !tile.container,
               let title = tile.aggregate ? "Small items" : labels[tile.id] {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingMiddle
                let display = NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: tile.aggregate ? NSColor.labelColor : kind < 0 ? NSColor.controlBackgroundColor : labelColors[kind],
                    .paragraphStyle: style
                ])
                display.draw(in: CGRect(x: frame.minX + 6, y: frame.minY + 5, width: frame.width - 12, height: 15))
            }
        }
        graphics.restoreGraphicsState()
    }
}

@MainActor private final class SelectionHighlight: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var rectangle: CGRect? {
        didSet {
            if let oldValue { setNeedsDisplay(oldValue) }
            if let rectangle { setNeedsDisplay(rectangle) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        guard let rectangle, rectangle.width > 4, rectangle.height > 4 else { return }
        let frame = rectangle.insetBy(dx: 1.75, dy: 1.75)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(3.5)
        context.stroke(frame)
        context.setStrokeColor(NSColor.windowBackgroundColor.cgColor)
        context.setLineWidth(1.75)
        context.stroke(frame)
    }
}
