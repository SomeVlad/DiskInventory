import AppKit
import SwiftUI
import InventoryCore

@MainActor final class Details: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    let root = NSView()
    let tabs = NSSegmentedControl(labels: ["Kinds", "Largest Files", "Clean Up"], trackingMode: .selectOne, target: nil, action: nil)
    private(set) var search = NSSearchField()
    let fields = NSPopUpButton()
    let filter = NSPopUpButton()
    private let kindsTable = InventoryResultsView()
    private let resultsTable = InventoryResultsView()
    var table: NSTableView { searching ? resultsTable : kindsTable }
    let count = NSTextField(labelWithString: "")
    var updateSearch: (() -> Void)?
    var tabChanged: (() -> Void)?
    var kindSelected: ((Int?) -> Void)?
    var quickLook: (() -> Void)?
    var didSelect: ((Int) -> Void)?
    var didOpen: ((Int) -> Void)?
    var menuForRow: ((Int) -> NSMenu?)?
    private let kindsScroll = NSScrollView()
    private let resultsScroll = NSScrollView()
    private let searchBar = NSStackView()
    private let usageView = NSHostingView(rootView: AnyView(EmptyView()))
    private let cleanupHost = NSHostingView(rootView: AnyView(
        ContentUnavailableView("Waiting for the Scan", systemImage: "hourglass",
                               description: Text("Clean-up suggestions and Claude’s advice appear when the scan finishes"))
    ))
    private let noResults = NSHostingView(rootView: ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("Try another name, kind or folder")))
    private let tableArea = NSView()
    private var searched = false
    private var snapshot: ScanSummary?
    private var totals: [KindTotal] = []
    private var shownTotals: [KindTotal] = []
    private var matches: [Int] = []
    func containsResult(_ id: Int) -> Bool { matches.contains(id) }
    private var colors: [NSColor] = []
    private var options = ViewOptions()
    private var silent = false
    private var selected: Int?
    private var filterKinds: [Int] = []
    private var filterIdentifier: String?
    var hasMatches: Bool { searching && !matches.isEmpty }
    var matchIDs: [Int] { matches }

    var searching: Bool { tabs.selectedSegment == 1 }
    var cleaning: Bool { tabs.selectedSegment == 2 }
    var selectedKind: Int? {
        guard !searching, !cleaning, shownTotals.indices.contains(kindsTable.selectedRow) else { return nil }
        return shownTotals[kindsTable.selectedRow].kind
    }
    var query: String { search.stringValue }
    var field: SearchField { SearchField(rawValue: fields.titleOfSelectedItem ?? "") ?? .all }
    var kind: Int? {
        let index = filter.indexOfSelectedItem - 1
        return filterKinds.indices.contains(index) ? filterKinds[index] : nil
    }

    override init() {
        super.init()
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(changeTab)
        search.placeholderString = "Search files"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        fields.addItems(withTitles: SearchField.allCases.map(\.rawValue))
        fields.setAccessibilityLabel("Search field")
        filter.setAccessibilityLabel("Filter by kind")
        filter.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filter.cell?.lineBreakMode = .byTruncatingTail
        for popup in [fields, filter] {
            popup.target = self
            popup.action = #selector(changeFilter)
            popup.controlSize = .small
        }
        filter.addItem(withTitle: "All kinds")
        searchBar.orientation = .vertical
        searchBar.alignment = .leading
        searchBar.spacing = 6
        searchBar.addArrangedSubview(search)
        let popups = NSStackView(views: [fields, filter])
        popups.spacing = 5
        searchBar.addArrangedSubview(popups)
        search.widthAnchor.constraint(equalTo: searchBar.widthAnchor).isActive = true
        count.textColor = .secondaryLabelColor
        count.font = .systemFont(ofSize: 11)
        configureColumns(kindsTable, in: kindsScroll, results: false)
        configureColumns(resultsTable, in: resultsScroll, results: true)
        for scroll in [kindsScroll, resultsScroll, noResults] {
            scroll.translatesAutoresizingMaskIntoConstraints = false
            tableArea.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: tableArea.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: tableArea.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: tableArea.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: tableArea.bottomAnchor)
            ])
        }
        resultsScroll.isHidden = true
        noResults.isHidden = true
        let stack = NSStackView(views: [tabs, usageView, searchBar, tableArea, count])
        usageView.isHidden = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        cleanupHost.translatesAutoresizingMaskIntoConstraints = false
        cleanupHost.isHidden = true
        root.addSubview(cleanupHost)
        NSLayoutConstraint.activate([
            cleanupHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            cleanupHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            cleanupHost.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            cleanupHost.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tableArea.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            usageView.widthAnchor.constraint(equalTo: tableArea.widthAnchor),
            searchBar.widthAnchor.constraint(equalTo: tableArea.widthAnchor),
            popups.widthAnchor.constraint(lessThanOrEqualTo: searchBar.widthAnchor)
        ])
        searchBar.isHidden = true
    }

    func display(snapshot: ScanSummary?, totals: [KindTotal]?, colors: [NSColor], options: ViewOptions) {
        self.snapshot = snapshot
        self.totals = totals ?? []
        self.colors = colors
        self.options = options
        usageView.isHidden = searching || cleaning || snapshot?.volume == nil
        if let snapshot, let volume = snapshot.volume, volume.capacity > 0 {
            usageView.rootView = AnyView(VolumeBreakdown(volume: volume, scanned: snapshot.nodes[0].allocated))
        } else {
            usageView.rootView = AnyView(EmptyView())
        }
        matches = []
        searched = false
        noResults.isHidden = true
        filterKinds = self.totals.map(\.kind)
        filter.removeAllItems()
        filter.addItem(withTitle: "All kinds")
        if let snapshot {
            for id in filterKinds {
                let title = snapshot.kinds[id].title
                let unique = filter.item(withTitle: title) == nil ? title : "\(title) (\(snapshot.kinds[id].identifier))"
                filter.addItem(withTitle: unique)
            }
            if let filterIdentifier {
                if let index = filterKinds.firstIndex(where: { snapshot.kinds[$0].identifier == filterIdentifier }) {
                    filter.selectItem(at: index + 1)
                } else if totals != nil {
                    self.filterIdentifier = nil
                }
            }
        }
        filter.isEnabled = !filterKinds.isEmpty
        sortTotals()
        kindsTable.reloadData()
        resultsTable.reloadData()
    }

    func recolor(_ colors: [NSColor]) {
        self.colors = colors
        if !searching { table.reloadData() }
    }

    func showList(kind: Int? = nil, query: String? = nil, focus: Bool = false) {
        if let kind, let index = filterKinds.firstIndex(of: kind) {
            filter.selectItem(at: index + 1)
        } else {
            filter.selectItem(at: 0)
        }
        rememberFilter()
        if let query { search.stringValue = query }
        openSearch(focus: focus)
    }

    func openSearch(focus: Bool = false) {
        if !searching {
            tabs.selectedSegment = 1
            changeTab()
        } else {
            updateSearch?()
        }
        if focus { root.window?.makeFirstResponder(search) }
    }

    func toggleList() {
        tabs.selectedSegment = searching ? 0 : 1
        changeTab()
    }

    func selectTab(_ index: Int) {
        guard tabs.selectedSegment != index else { return }
        tabs.selectedSegment = index
        changeTab()
    }

    func adopt(searchField field: NSSearchField) {
        guard field !== search else { return }
        field.placeholderString = "Search files"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.stringValue = search.stringValue
        searchBar.removeArrangedSubview(search)
        search.removeFromSuperview()
        search = field
    }

    func showCleanup(_ view: AnyView) {
        cleanupHost.rootView = view
    }

    func showMatches(_ ids: [Int]) {
        guard searching else { return }
        matches = ids
        searched = true
        count.stringValue = ids.isEmpty ? "" : ids.count.formatted() + " items"
        noResults.isHidden = !ids.isEmpty
        resultsTable.reloadData()
        tabChanged?()
        if searching { sync(selected) }
    }

    func searchStarted() {
        count.stringValue = "Searching…"
        noResults.isHidden = true
        matches.removeAll()
        resultsTable.reloadData()
    }

    func sync(_ id: Int?) {
        selected = id
        silent = true
        defer { silent = false }
        guard let id, let snapshot, snapshot.nodes.indices.contains(id) else {
            table.deselectAll(nil)
            return
        }
        let index = searching
            ? matchIndex(id, snapshot: snapshot)
            : shownTotals.firstIndex { $0.kind == Int(snapshot.nodes[id].kind) }
        if let index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
    }

    private func matchIndex(_ id: Int, snapshot: ScanSummary) -> Int? {
        var low = 0
        var high = matches.count
        while low < high {
            let middle = low + (high - low) / 2
            if snapshot.searchSortsBefore(matches[middle], id, mode: options.mode) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < matches.count && matches[low] == id ? low : nil
    }

    func next() {
        guard searching, !matches.isEmpty else { return }
        let index = (table.selectedRow + 1) % matches.count
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    @objc private func changeTab() {
        searchBar.isHidden = !searching
        usageView.isHidden = searching || cleaning || snapshot?.volume == nil
        resultsScroll.isHidden = !searching
        kindsScroll.isHidden = searching
        noResults.isHidden = !(searching && searched && matches.isEmpty)
        tableArea.isHidden = cleaning
        count.isHidden = cleaning
        cleanupHost.isHidden = !cleaning
        defer { tabChanged?() }
        if searching {
            updateSearch?()
        } else {
            sortTotals()
        }
        sync(selected)
    }

    private func rememberFilter() {
        filterIdentifier = kind.flatMap { snapshot?.kinds[$0].identifier }
    }

    @objc private func changeFilter() {
        rememberFilter()
        updateSearch?()
    }

    func controlTextDidChange(_ obj: Notification) {
        if searching { updateSearch?() } else { openSearch() }
    }
    @objc private func doubleClick(_ sender: NSTableView) { _ = activate(sender, row: sender.clickedRow) }

    private func activate(_ table: NSTableView, row: Int) -> Bool {
        if table === resultsTable, matches.indices.contains(row) {
            didOpen?(matches[row])
        } else if table === kindsTable, shownTotals.indices.contains(row) {
            showList(kind: shownTotals[row].kind, query: "", focus: true)
        } else {
            return false
        }
        return true
    }

    private func configureColumns(_ table: InventoryResultsView, in scroll: NSScrollView, results: Bool) {
        let columns: [(String, String, CGFloat, CGFloat)] = results
            ? [("name", "Name", 95, 140), ("size", "Size", 63, 76), ("path", "Folder", 80, 160)]
            : [("kind", "Kind", 100, 132), ("size", "Size", 62, 74), ("files", "Files", 48, 56)]
        for (id, title, minimumWidth, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.minWidth = minimumWidth
            column.width = width
            if !results { column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "kind") }
            table.addTableColumn(column)
        }
        if !results { table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)] }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClick(_:))
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.configureInventoryColumns(results ? "Results" : "Kinds", in: scroll)
        table.setAccessibilityLabel(results ? "File search results" : "File kind statistics")
        table.activateRow = { [weak self, weak table] in
            guard let table else { return false }
            return self?.activate(table, row: table.selectedRow) ?? false
        }
        if results { table.quickLook = { [weak self] in self?.quickLook?() } }
    }

    private func sortTotals() {
        guard let snapshot else {
            shownTotals = []
            count.stringValue = ""
            return
        }
        let descriptor = kindsTable.sortDescriptors.first
        shownTotals = totals.sorted { lhs, rhs in
            let order: ComparisonResult
            switch descriptor?.key {
            case "kind": order = snapshot.kinds[lhs.kind].title.localizedStandardCompare(snapshot.kinds[rhs.kind].title)
            case "files": order = lhs.count == rhs.count ? .orderedSame : (lhs.count < rhs.count ? .orderedAscending : .orderedDescending)
            default: order = lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
            }
            return order == .orderedSame ? lhs.kind < rhs.kind
                : order == (descriptor?.ascending == true ? .orderedAscending : .orderedDescending)
        }
        if !searching {
            count.stringValue = "\(totals.count.formatted()) kinds · \(totals.reduce(0) { $0 + $1.count }.formatted()) items"
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === kindsTable else { return }
        sortTotals()
        kindsTable.reloadData()
        if !searching { sync(selected) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === resultsTable ? matches.count : shownTotals.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let snapshot, let key = tableColumn?.identifier.rawValue else { return nil }
        let title: String
        var textColor = NSColor.secondaryLabelColor
        if tableView === resultsTable {
            guard matches.indices.contains(row) else { return nil }
            let id = matches[row]
            switch key {
            case "size": title = formatSize(snapshot.size(of: id, options: options))
            case "path": title = snapshot.displayPath(of: Int(max(0, snapshot.nodes[id].parent)))
            default:
                title = snapshot.nodes[id].name
                textColor = .labelColor
            }
        } else {
            guard shownTotals.indices.contains(row) else { return nil }
            let entry = shownTotals[row]
            if key == "kind" {
                let cell = tableView.makeView(withIdentifier: KindCell.identifier, owner: self) as? KindCell ?? KindCell()
                cell.configure(title: snapshot.kinds[entry.kind].title, color: colors.indices.contains(entry.kind) ? colors[entry.kind] : .systemGray)
                return cell
            }
            title = key == "files" ? entry.count.formatted() : formatSize(entry.size)
        }
        let cell = tableView.makeView(withIdentifier: TextCell.identifier, owner: self) as? TextCell ?? TextCell()
        cell.configure(text: title, color: textColor, numeric: key == "size" || key == "files")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === kindsTable, !searching {
            if !silent { kindSelected?(selectedKind) }
            return
        }
        guard !silent, searching, notification.object as? NSTableView === resultsTable,
              matches.indices.contains(resultsTable.selectedRow) else { return }
        didSelect?(matches[resultsTable.selectedRow])
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === resultsTable, matches.indices.contains(row) else { return nil }
        return snapshot?.url(for: matches[row]) as NSURL?
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard menu === table.menu else { return }
        if searching, matches.indices.contains(table.clickedRow), let source = menuForRow?(matches[table.clickedRow]) {
            for item in source.items {
                source.removeItem(item)
                menu.addItem(item)
            }
        } else if !searching, shownTotals.indices.contains(table.clickedRow) {
            let item = NSMenuItem(title: "Show in Largest Files", action: #selector(showKind(_:)), keyEquivalent: "")
            item.tag = shownTotals[table.clickedRow].kind
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func showKind(_ item: NSMenuItem) { showList(kind: item.tag, query: "") }
}


@MainActor private final class InventoryResultsView: NSTableView {
    var activateRow: (() -> Bool)?
    var quickLook: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if event.keyCode == 49, plain, let quickLook {
            quickLook()
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76), plain, activateRow?() == true { return }
        super.keyDown(with: event)
    }
}


@MainActor final class TextCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TextCell")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, color: NSColor, numeric: Bool, size: CGFloat = 13) {
        guard let field = textField else { return }
        field.stringValue = text
        field.toolTip = text
        field.textColor = color
        field.alignment = numeric ? .right : .natural
        field.lineBreakMode = numeric ? .byTruncatingHead : .byTruncatingMiddle
        field.font = numeric ? .monospacedDigitSystemFont(ofSize: size - 1, weight: .regular) : .systemFont(ofSize: size)
    }
}

@MainActor final class KindCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("KindCell")
    private let dot = NSView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [dot, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = field
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            field.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, color: NSColor) {
        let shown = title.prefix(1).uppercased() + title.dropFirst()
        textField?.stringValue = shown
        textField?.toolTip = shown
        dot.layer?.backgroundColor = color.cgColor
        setAccessibilityLabel(title)
    }
}
