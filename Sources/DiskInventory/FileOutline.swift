import AppKit
import InventoryCore
import UniformTypeIdentifiers

@MainActor final class FileOutline: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let view = InventoryOutlineView()
    let scroll = NSScrollView()
    var selectedID: Int? {
        guard view.selectedRow >= 0, let row = view.item(atRow: view.selectedRow) as? Row, !row.isPageControl else { return nil }
        return row.id
    }
    var didSelect: ((Int?) -> Void)?
    var didOpen: ((Int) -> Void)?
    var menuForRow: ((Int) -> NSMenu?)?
    private var snapshot: ScanSummary?
    private var options = ViewOptions()
    private var root = 0
    private var cache: [Int: [Int]] = [:]
    private var sorting: [Int: Task<[Int], Error>] = [:]
    private var pendingReveal: Int?
    private var sortGeneration = UUID()
    private var boxes: [Int: Row] = [:]
    private var sortingRows: [Int: Row] = [:]
    private var nextPages: [Int: Row] = [:]
    private var previousPages: [Int: Row] = [:]
    private var offsets: [Int: Int] = [:]
    private var silent = false
    private var smallFont = false
    var isCompact: Bool { smallFont }
    private var icons: [String: NSImage] = [:]
    private let pageSize = 600

    private final class Row: NSObject {
        let id: Int
        let pageDirection: Int
        var isPageControl: Bool { pageDirection != 0 }

        init(id: Int, pageDirection: Int = 0) {
            self.id = id
            self.pageDirection = pageDirection
        }
    }

    override init() {
        super.init()
        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Name"
        name.minWidth = 76
        name.width = 176
        name.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "Size"
        size.minWidth = 65
        size.width = 88
        size.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
        view.addTableColumn(name)
        view.addTableColumn(size)
        view.outlineTableColumn = name
        view.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        view.rowSizeStyle = .default
        view.usesAlternatingRowBackgroundColors = true
        view.indentationPerLevel = 13
        view.style = .inset
        view.autoresizesOutlineColumn = false
        view.setAccessibilityLabel("Files and folders")
        view.dataSource = self
        view.delegate = self
        view.target = self
        view.doubleAction = #selector(doubleClick)
        view.menu = NSMenu()
        view.menu?.delegate = self
        view.registerForDraggedTypes([])
        view.setDraggingSourceOperationMask(.copy, forLocal: false)
        scroll.borderType = .noBorder
        view.configureInventoryColumns("Files", in: scroll)
        view.activateRow = { [weak self] in
            guard let self else { return false }
            return activate(rowAt: view.selectedRow)
        }
    }

    func setCompactText(_ compact: Bool) {
        guard smallFont != compact else { return }
        smallFont = compact
        if view.numberOfRows > 0 {
            let range = view.rows(in: view.visibleRect)
            if range.location != NSNotFound, range.length > 0 {
                let visible = IndexSet(integersIn: range.location..<(range.location + range.length))
                view.reloadData(forRowIndexes: visible, columnIndexes: IndexSet(integersIn: 0..<view.numberOfColumns))
            }
        }
    }

    func display(_ snapshot: ScanSummary?, root: Int, options: ViewOptions) {
        silent = true
        view.collapseItem(nil, collapseChildren: true)
        self.snapshot = snapshot
        self.root = root
        self.options = options
        smallFont = Settings.bool("smallFont")
        cancelSorting()
        cache.removeAll()
        boxes.removeAll()
        sortingRows.removeAll()
        nextPages.removeAll()
        previousPages.removeAll()
        offsets.removeAll()
        icons.removeAll()
        view.reloadData()
        silent = false
    }

    func reveal(_ id: Int?) {
        pendingReveal = id
        silent = true
        defer { silent = false }
        guard let id, let snapshot else {
            view.deselectAll(nil)
            return
        }
        let ancestry = id < 0 ? [0, id] : snapshot.lineage(of: id)
        guard let start = ancestry.firstIndex(of: root) else {
            pendingReveal = nil
            view.deselectAll(nil)
            return
        }
        let path = ancestry.dropFirst(start + 1)
        if path.isEmpty {
            pendingReveal = nil
            view.deselectAll(nil)
            return
        }
        var parent = root
        for child in path {
            guard let index = children(parent).firstIndex(of: child) else {
                if sorting[parent] == nil { pendingReveal = nil }
                return
            }
            let page = offset(parent)
            if index < page || index >= page + pageSize {
                showPage(parent, offset: index / pageSize * pageSize)
            }
            if child != id { view.expandItem(row(child)) }
            parent = child
        }
        pendingReveal = nil
        let index = view.row(forItem: row(id))
        if index >= 0 {
            view.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            view.scrollRowToVisible(index)
        }
    }

    private func row(_ id: Int) -> Row {
        if let existing = boxes[id] { return existing }
        let row = Row(id: id)
        boxes[id] = row
        return row
    }

    func cancelSorting() {
        sortGeneration = UUID()
        sorting.values.forEach { $0.cancel() }
        sorting.removeAll()
        pendingReveal = nil
    }

    private func children(_ id: Int) -> [Int] {
        if let existing = cache[id] { return existing }
        guard sorting[id] == nil, let snapshot, snapshot.nodes.indices.contains(id) else { return [] }
        let descriptor = view.sortDescriptors.first
        let byName = descriptor?.key == "name"
        let ascending = descriptor?.ascending == true
        let options = options
        var child = snapshot.nodes[id].firstChild
        for _ in 0..<512 {
            if child < 0 { break }
            child = snapshot.nodes[Int(child)].nextSibling
        }
        if child < 0 || !snapshot.isExpandable(id, options: options) {
            let sorted = Self.sorted(snapshot, id: id, options: options, byName: byName, ascending: ascending)
            cache[id] = sorted
            return sorted
        }
        let generation = sortGeneration
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = Self.sorted(snapshot, id: id, options: options, byName: byName, ascending: ascending)
            try Task.checkCancellation()
            return result
        }
        sorting[id] = worker
        Task { [weak self] in
            guard let rows = try? await worker.value, let self, sortGeneration == generation else { return }
            sorting.removeValue(forKey: id)
            let restore = pendingReveal
            silent = true
            cache[id] = rows
            if id == root {
                view.reloadData()
            } else if let item = boxes[id], view.isItemExpanded(item) {
                view.reloadItem(item, reloadChildren: true)
            }
            silent = false
            if let restore { reveal(restore) }
        }
        return []
    }

    private nonisolated static func sorted(
        _ snapshot: ScanSummary, id: Int, options: ViewOptions, byName: Bool, ascending: Bool
    ) -> [Int] {
        if !byName {
            let ids = snapshot.sortedChildren(of: id, options: options)
            return ascending ? Array(ids.reversed()) : ids
        }
        let name: (Int) -> String = { id in
            if id == -1 { return "Free Space" }
            if id == -2 { return "Other Space" }
            return snapshot.nodes[id].name
        }
        return snapshot.visibleChildren(of: id, options: options).sorted {
            let order = name($0).localizedStandardCompare(name($1))
            return order == .orderedSame ? $0 < $1 : (ascending ? order == .orderedAscending : order == .orderedDescending)
        }
    }

    private func title(_ id: Int) -> String {
        if id == -1 { return "Free Space" }
        if id == -2 { return "Other Space" }
        return snapshot?.nodes[id].name ?? ""
    }

    private func offset(_ id: Int) -> Int { offsets[id, default: 0] }

    private func showPage(_ parent: Int, offset: Int) {
        let item: Row? = parent == root ? nil : row(parent)
        let expanded = item.map { view.isItemExpanded($0) } ?? true
        if let item, expanded { view.collapseItem(item, collapseChildren: true) }
        if item == nil { view.collapseItem(nil, collapseChildren: true) }
        offsets[parent] = offset
        view.reloadItem(item, reloadChildren: true)
        if let item, expanded { view.expandItem(item) }
    }

    private func pageControl(_ parent: Int, direction: Int) -> Row {
        if let row = direction < 0 ? previousPages[parent] : nextPages[parent] { return row }
        let row = Row(id: parent, pageDirection: direction)
        if direction < 0 { previousPages[parent] = row } else { nextPages[parent] = row }
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let parent = (item as? Row)?.id ?? root
        guard parent >= 0 else { return 0 }
        let count = children(parent).count
        if sorting[parent] != nil { return 1 }
        let offset = offset(parent)
        return min(pageSize, max(0, count - offset)) + (offset > 0 ? 1 : 0) + (offset + pageSize < count ? 1 : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let parent = (item as? Row)?.id ?? root
        if sorting[parent] != nil {
            if let row = sortingRows[parent] { return row }
            let row = Row(id: parent, pageDirection: 2)
            sortingRows[parent] = row
            return row
        }
        let page = offset(parent)
        if page > 0 && index == 0 { return pageControl(parent, direction: -1) }
        let paged = index - (page > 0 ? 1 : 0)
        let ids = children(parent)
        if paged < pageSize, ids.indices.contains(page + paged) { return row(ids[page + paged]) }
        return pageControl(parent, direction: 1)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let row = item as? Row, row.id >= 0, !row.isPageControl, let snapshot else { return false }
        return snapshot.nodes[row.id].firstChild >= 0 && snapshot.isExpandable(row.id, options: options)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row, let snapshot else { return nil }
        guard row.isPageControl || row.id < 0 || snapshot.nodes.indices.contains(row.id) else { return nil }
        let font = NSFont.systemFont(ofSize: smallFont ? 11 : 13)
        if tableColumn?.identifier.rawValue == "size" {
            let label = NSTextField(labelWithString: row.isPageControl ? "" : formatSize(snapshot.size(of: row.id, options: options)))
            label.alignment = .right
            label.font = .monospacedDigitSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        if row.isPageControl {
            let title = row.pageDirection == 2 ? "Sorting…" : row.pageDirection < 0 ? "‹ Previous items" : "Next items ›"
            let label = NSTextField(labelWithString: title)
            label.textColor = .controlAccentColor
            label.font = font
            return label
        }
        let label = NSTextField(labelWithString: title(row.id))
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = label.stringValue
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.font = font
        let icon = NSImageView(image: icon(for: row.id, snapshot: snapshot))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 5
        stack.alignment = .centerY
        return stack
    }

    private func icon(for id: Int, snapshot: ScanSummary) -> NSImage {
        guard id >= 0 else {
            return NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil) ?? NSImage()
        }
        let kind = snapshot.kinds[Int(snapshot.nodes[id].kind)]
        if let icon = icons[kind.identifier] { return icon }
        let typeIdentifier = kind.identifier.split(separator: "|", maxSplits: 1).first.map(String.init) ?? kind.identifier
        let icon = NSWorkspace.shared.icon(for: UTType(typeIdentifier) ?? (snapshot.nodes[id].isDirectory ? .folder : .data))
        icons[kind.identifier] = icon
        return icon
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !silent else { return }
        pendingReveal = nil
        didSelect?(selectedID)
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let current = selectedID
        cancelSorting()
        offsets.removeAll()
        cache.removeAll()
        silent = true
        view.reloadData()
        silent = false
        reveal(current)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let row = item as? Row, row.id >= 0, !row.isPageControl else { return nil }
        return snapshot?.url(for: row.id) as NSURL?
    }

    @objc private func doubleClick() { _ = activate(rowAt: view.clickedRow) }

    private func activate(rowAt index: Int) -> Bool {
        guard index >= 0, let row = view.item(atRow: index) as? Row, row.pageDirection != 2 else { return false }
        if row.isPageControl {
            let previous = offset(row.id)
            let newOffset = previous + pageSize * row.pageDirection
            showPage(row.id, offset: newOffset)
            let ids = children(row.id)
            if ids.indices.contains(newOffset) {
                let id = ids[newOffset]
                reveal(id)
                didSelect?(id)
            }
        } else {
            didOpen?(row.id)
        }
        return true
    }
}

extension FileOutline: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard view.clickedRow >= 0, let row = view.item(atRow: view.clickedRow) as? Row,
              !row.isPageControl, let source = menuForRow?(row.id) else { return }
        for item in source.items {
            source.removeItem(item)
            menu.addItem(item)
        }
    }
}

@MainActor final class InventoryOutlineView: NSOutlineView {
    var activateRow: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           activateRow?() == true { return }
        super.keyDown(with: event)
    }
}
