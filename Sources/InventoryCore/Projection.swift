import CoreGraphics
import Foundation

public struct ViewOptions: Hashable, Sendable {
    public var mode: SizeMode = .allocated
    public var packages = false
    public var free = false
    public var other = false

    public init() {}
}

public struct KindTotal: Sendable {
    public let kind: Int
    public var size: Int64 = 0
    public var count: Int = 0
}

public enum SearchField: String, CaseIterable, Sendable {
    case all = "All", name = "Name", kind = "Kind", path = "Path"
}

public extension ScanSummary {
    func isExpandable(_ id: Int, options: ViewOptions) -> Bool {
        nodes[id].isDirectory && (id == 0 || options.packages || !kinds[Int(nodes[id].kind)].isPackage)
    }

    func size(of id: Int, options: ViewOptions) -> Int64 {
        guard id >= 0 else {
            guard let volume else { return 0 }
            return id == -1 ? volume.free : max(0, volume.capacity - volume.free - nodes[0].allocated)
        }
        return nodes[id].size(options.mode)
    }

    func visibleChildren(of id: Int, options: ViewOptions) -> [Int] {
        var ids = isExpandable(id, options: options) ? children(of: id) : []
        if id == 0 {
            if options.free, size(of: -1, options: options) > 0 { ids.append(-1) }
            if options.other, size(of: -2, options: options) > 0 { ids.append(-2) }
        }
        return ids
    }

    func sortedChildren(of id: Int, options: ViewOptions) -> [Int] {
        visibleChildren(of: id, options: options).sorted {
            let sizeA = size(of: $0, options: options)
            let sizeB = size(of: $1, options: options)
            return sizeA == sizeB ? $0 < $1 : sizeA > sizeB
        }
    }

    func kindTotals(options: ViewOptions) throws -> [KindTotal] {
        var totals = kinds.indices.map { KindTotal(kind: $0) }
        try visitFiles(options: options) { _, node in
            let kind = Int(node.kind)
            totals[kind].size += node.size(options.mode)
            totals[kind].count += 1
        }
        return totals.filter { $0.count > 0 }.sorted {
            $0.size == $1.size ? kinds[$0.kind].title < kinds[$1.kind].title : $0.size > $1.size
        }
    }

    func search(_ query: String, field: SearchField, kind: Int?, options: ViewOptions) throws -> [Int] {
        var matches: [Int] = []
        try visitFiles(options: options) { id, node in
            if let kind, Int(node.kind) != kind { return }
            if query.isEmpty
                || ((field == .all || field == .name) && node.name.localizedStandardContains(query))
                || ((field == .all || field == .kind) && kinds[Int(node.kind)].title.localizedStandardContains(query))
                || ((field == .all || field == .path) && url(for: id).path.localizedStandardContains(query)) {
                matches.append(id)
            }
        }
        return matches.sorted { searchSortsBefore($0, $1, mode: options.mode) }
    }

    func searchSortsBefore(_ first: Int, _ second: Int, mode: SizeMode) -> Bool {
        let a = nodes[first].size(mode)
        let b = nodes[second].size(mode)
        return a == b ? first < second : a > b
    }

    private func visitFiles(options: ViewOptions, _ body: (Int, FileNode) -> Void) throws {
        var id: Int32 = nodes[0].firstChild
        var visited = 0
        while id >= 0 {
            if visited.isMultiple(of: 1024) { try Task.checkCancellation() }
            visited += 1
            let item = nodes[Int(id)]
            if isExpandable(Int(id), options: options) {
                if item.firstChild >= 0 {
                    id = item.firstChild
                    continue
                }
            } else {
                body(Int(id), item)
            }
            while id > 0, nodes[Int(id)].nextSibling < 0 {
                id = nodes[Int(id)].parent
            }
            id = id > 0 ? nodes[Int(id)].nextSibling : -1
        }
    }
}

public struct MapTile: Sendable {
    public let id: Int
    public let rect: CGRect
    public let container: Bool
    public let aggregate: Bool
    public var header: CGFloat = 0
}

public enum TreemapLayout {
    public static let headerHeight: CGFloat = 16

    public static func make(snapshot: ScanSummary, focus: Int, size: CGSize, options: ViewOptions) throws -> [MapTile] {
        var tiles: [MapTile] = []
        let bounds = CGRect(origin: .zero, size: size)
        guard bounds.width >= 1, bounds.height >= 1 else { return [] }
        try layout(snapshot: snapshot, id: focus, rect: bounds, depth: 0, options: options, into: &tiles)
        return tiles
    }

    private struct Entry {
        let id: Int
        let area: CGFloat
        var aggregate = false
    }

    private static func layout(
        snapshot: ScanSummary, id: Int, rect: CGRect, depth: Int, options: ViewOptions, into tiles: inout [MapTile]
    ) throws {
        try Task.checkCancellation()
        let container = id >= 0 && snapshot.isExpandable(id, options: options)
        let header = depth > 0 && container && rect.width >= 64 && rect.height >= headerHeight + 28 ? headerHeight : 0
        if depth > 0 {
            tiles.append(MapTile(id: id, rect: rect, container: container, aggregate: false, header: header))
        }
        guard container, depth < 24, rect.width >= 6, rect.height >= 6, tiles.count < 12_000 else { return }
        let inner = depth == 0 ? rect
            : CGRect(x: rect.minX + 1, y: rect.minY + max(1, header), width: rect.width - 2, height: rect.height - max(1, header) - 1)
        let children = snapshot.sortedChildren(of: id, options: options)
        let combined = children.reduce(0.0) { $0 + Double(snapshot.size(of: $1, options: options)) }
        guard combined > 0 else { return }
        let scale = inner.width * inner.height / combined
        let limit = min(1600, max(1, 12_000 - tiles.count))
        var entries: [Entry] = []
        var shown = 0.0
        for child in children.prefix(limit) {
            let weight = Double(snapshot.size(of: child, options: options))
            let area = weight * scale
            if area < 5 { break }
            entries.append(Entry(id: child, area: area))
            shown += weight
        }
        if combined > shown {
            entries.append(Entry(id: id, area: (combined - shown) * scale, aggregate: true))
        }
        var remaining = inner
        var start = 0
        while start < entries.count, remaining.width > 0, remaining.height > 0 {
            let short = min(remaining.width, remaining.height)
            var end = start + 1
            var area = entries[start].area
            var smallest = area
            var largest = area
            while end < entries.count {
                let next = entries[end].area
                let proposed = area + next
                let nextSmallest = min(smallest, next)
                let nextLargest = max(largest, next)
                if aspect(short, proposed, nextLargest, nextSmallest) > aspect(short, area, largest, smallest) { break }
                area = proposed
                smallest = nextSmallest
                largest = nextLargest
                end += 1
            }
            let vertical = remaining.width >= remaining.height
            let thickness = min(area / short, vertical ? remaining.width : remaining.height)
            var offset: CGFloat = 0
            for index in start..<end {
                let entry = entries[index]
                let length = min(short - offset, entry.area / thickness)
                guard length > 0 else { continue }
                let frame = vertical
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                if entry.aggregate || tiles.count >= 12_000 {
                    tiles.append(MapTile(id: id, rect: frame, container: false, aggregate: true))
                } else {
                    try layout(snapshot: snapshot, id: entry.id, rect: frame, depth: depth + 1, options: options, into: &tiles)
                }
                offset += length
            }
            if vertical {
                remaining.origin.x += thickness
                remaining.size.width -= thickness
            } else {
                remaining.origin.y += thickness
                remaining.size.height -= thickness
            }
            start = end
        }
    }

    private static func aspect(_ side: CGFloat, _ area: CGFloat, _ largest: CGFloat, _ smallest: CGFloat) -> CGFloat {
        let ratio = (side / area) * (side / area)
        return max(largest * ratio, 1 / (smallest * ratio))
    }
}
