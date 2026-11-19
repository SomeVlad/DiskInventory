import Foundation
import InventoryCore

func syncTool(_ name: String, _ description: String, _ schema: [String: Any], _ body: @escaping (Params) throws -> Any) -> Tool {
    Tool(name: name, description: description, schema: schema) { params, completion in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                completion(.success(try body(params)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

private let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
}()

func human(_ bytes: Int64) -> String { byteFormatter.string(fromByteCount: bytes) }

func percent(_ part: Int64, of total: Int64) -> Any {
    total > 0 ? (Double(part) / Double(total) * 1000).rounded() / 10 : NSNull()
}

func resolvePath(_ raw: String) -> String {
    let url = URL(filePath: (raw as NSString).expandingTildeInPath).standardizedFileURL
    return url.path.isEmpty ? "/" : url.path
}

func sizeArgument(_ params: Params, _ key: String, fallback: Int64) throws -> Int64 {
    guard let text = params.string(key) else { return fallback }
    let normalized = text.uppercased().replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
    let units: [(String, Int64)] = [
        ("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10),
        ("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10), ("B", 1),
    ]
    for (suffix, factor) in units where normalized.hasSuffix(suffix) {
        guard let value = Double(normalized.dropLast(suffix.count)), value >= 0 else {
            throw ToolFailure("\(key): \(text) is not a size; use bytes or a suffix such as 500M or 2G")
        }
        return Int64(value * Double(factor))
    }
    guard let value = Double(normalized), value >= 0 else {
        throw ToolFailure("\(key): \(text) is not a size; use bytes or a suffix such as 500M or 2G")
    }
    return Int64(value)
}

func hasFullDiskAccess() -> Bool {
    let descriptor = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
    guard descriptor >= 0 else { return false }
    close(descriptor)
    return true
}

struct StoredScan {
    let snapshot: ScanSummary
    let path: String
    let finderKinds: Bool
    let seconds: Double
    let finishedAt: Date

    var summary: [String: Any] {
        let root = snapshot.nodes[0]
        return [
            "path": path,
            "entries": snapshot.nodes.count,
            "files": root.fileCount,
            "allocated": root.allocated,
            "allocated_h": human(root.allocated),
            "logical": root.logical,
            "logical_h": human(root.logical),
            "skipped": snapshot.issueCount,
            "traversal": snapshot.traversal.rawValue,
            "finder_kinds": finderKinds,
            "scanned_in_seconds": (seconds * 10).rounded() / 10,
            "finished_at": finishedAt,
        ]
    }
}

final class ScanStore {
    private let lock = NSLock()
    private var scans: [String: StoredScan] = [:]

    func cached(path: String, finderKinds: Bool, maxAge: Double) -> StoredScan? {
        lock.withLock {
            guard let scan = scans[path], scan.finderKinds == finderKinds || !finderKinds,
                  Date().timeIntervalSince(scan.finishedAt) <= maxAge else { return nil }
            return scan
        }
    }

    func store(_ scan: StoredScan) {
        lock.withLock { scans[scan.path] = scan }
    }

    var all: [StoredScan] {
        lock.withLock { scans.values.sorted { $0.finishedAt > $1.finishedAt } }
    }
}

private final class ScanOutcome: @unchecked Sendable {
    var result: Result<ScanSummary, Error>?
}

func scanArguments(_ params: Params, store: ScanStore, defaultPath: String = "~") throws -> StoredScan {
    let path = resolvePath(params.string("path") ?? defaultPath)
    let finderKinds = try params.flag("finder_kinds", fallback: false)
    let maxAge = try params.seconds("max_age_seconds", fallback: 1800, limit: 86_400)
    if try !params.flag("refresh", fallback: false), let cached = store.cached(path: path, finderKinds: finderKinds, maxAge: maxAge) {
        return cached
    }
    let maxSeconds = try params.seconds("max_seconds", fallback: 120, limit: 1800)
    let started = Date()
    let outcome = ScanOutcome()
    let finished = DispatchSemaphore(value: 0)
    let task = Task.detached(priority: .userInitiated) {
        outcome.result = Result { try InventoryScanner.scan(URL(filePath: path, directoryHint: .isDirectory), ignoreCreatorCode: !finderKinds) }
        finished.signal()
    }
    if finished.wait(timeout: .now() + maxSeconds) == .timedOut {
        task.cancel()
        finished.wait()
        throw ToolFailure("the scan of \(path) was still running after \(Int(maxSeconds)) s; raise max_seconds or scan a smaller folder")
    }
    let scan = StoredScan(snapshot: try outcome.result!.get(), path: path, finderKinds: finderKinds,
                          seconds: Date().timeIntervalSince(started), finishedAt: Date())
    store.store(scan)
    return scan
}

let scanProperties: [String: Any] = [
    "path": Schema.text("folder or volume to scan (default ~); the boot volume is /System/Volumes/Data"),
    "finder_kinds": Schema.boolean("name file kinds the way Finder does (slower)"),
    "refresh": Schema.boolean("scan again instead of reusing the scan this server holds"),
    "max_age_seconds": Schema.number("reuse a scan younger than this (default 1800)"),
    "max_seconds": Schema.number("give up on a new scan after this many seconds (default 120, max 1800)"),
]

func withScanProperties(_ properties: [String: Any]) -> [String: Any] {
    properties.merging(scanProperties) { own, _ in own }
}

func sizeMode(_ params: Params) throws -> SizeMode {
    try params.choice("mode", options: ["allocated", "logical"], fallback: "allocated") == "logical" ? .logical : .allocated
}

func focus(_ params: Params, in scan: StoredScan) throws -> Int {
    guard let under = params.string("under") else { return 0 }
    let absolute = under.hasPrefix("/") || under.hasPrefix("~") ? resolvePath(under) : scan.path + "/" + under
    guard let id = scan.snapshot.locate(absolute) else { throw ToolFailure("\(under) is not inside the scan of \(scan.path)") }
    return id
}

func entryJSON(_ snapshot: ScanSummary, _ id: Int, mode: SizeMode, total: Int64) -> [String: Any] {
    let node = snapshot.nodes[id]
    let size = node.size(mode)
    var json: [String: Any] = [
        "path": snapshot.displayPath(of: id),
        "size": size,
        "size_h": human(size),
        "kind": snapshot.kinds[Int(node.kind)].title,
        "share_percent": percent(size, of: total),
    ]
    if node.isDirectory { json["files"] = node.fileCount }
    return json
}

func subtree(_ snapshot: ScanSummary, from root: Int, _ visit: (Int) -> Void) {
    var stack = [root]
    while let id = stack.popLast() {
        var child = snapshot.nodes[id].firstChild
        while child >= 0 {
            visit(Int(child))
            if snapshot.nodes[Int(child)].isDirectory { stack.append(Int(child)) }
            child = snapshot.nodes[Int(child)].nextSibling
        }
    }
}

func largest(_ snapshot: ScanSummary, from root: Int, limit: Int, mode: SizeMode, where include: (FileNode) -> Bool) -> [Int] {
    var best: [(size: Int64, id: Int)] = []
    subtree(snapshot, from: root) { id in
        let node = snapshot.nodes[id]
        guard include(node) else { return }
        let size = node.size(mode)
        if best.count == limit, let last = best.last, size <= last.size { return }
        let position = best.firstIndex { size > $0.size } ?? best.count
        best.insert((size, id), at: position)
        if best.count > limit { best.removeLast() }
    }
    return best.map(\.id)
}

private let formatterISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
}()

func makeTools(_ store: ScanStore) -> [Tool] {
    [
        syncTool(
            "inventory_status",
            "Whether this server can read protected folders, which cloud folders (iCloud Drive, Google Drive, OneDrive, Dropbox) are set up on this Mac, and the scans it holds.",
            Schema.object([:])
        ) { _ in
            [
                "full_disk_access": hasFullDiskAccess(),
                "cloud_destinations": CloudOffload.destinations().map { ["service": $0.service.rawValue, "title": $0.title, "root": $0.root.path] },
                "scans_in_memory": store.all.map(\.summary),
            ]
        },

        syncTool(
            "inventory_scan",
            "Scan a folder or volume the way Disk Inventory does: every file and folder is kept, read in parallel with getattrlistbulk on APFS. Returns totals and the biggest top-level items; the other inventory_* tools reuse this scan.",
            Schema.object(withScanProperties([
                "limit": Schema.integer("top-level items to list (default 12)"),
            ]))
        ) { params in
            let scan = try scanArguments(params, store: store)
            let limit = try params.count("limit", fallback: 12, limit: 100)
            let snapshot = scan.snapshot
            let total = snapshot.nodes[0].allocated
            let children = snapshot.children(of: 0).sorted { snapshot.nodes[$0].allocated > snapshot.nodes[$1].allocated }
            return [
                "scan": scan.summary,
                "top": children.prefix(limit).map { entryJSON(snapshot, $0, mode: .allocated, total: total) },
                "skipped_examples": snapshot.issues.prefix(15).map { ["path": $0.path, "reason": $0.message] },
            ]
        },

        syncTool(
            "inventory_children",
            "The items directly inside one folder of a scan, biggest first — for walking the tree level by level.",
            Schema.object(withScanProperties([
                "under": Schema.text("folder inside the scan, absolute or relative to its root (default the root)"),
                "limit": Schema.integer("items to return (default 25, max 500)"),
                "mode": Schema.choice("size on disk or logical size (default allocated)", ["allocated", "logical"]),
            ]))
        ) { params in
            let scan = try scanArguments(params, store: store)
            let snapshot = scan.snapshot
            let id = try focus(params, in: scan)
            let mode = try sizeMode(params)
            let limit = try params.count("limit", fallback: 25, limit: 500)
            let total = snapshot.nodes[id].size(mode)
            let children = snapshot.children(of: id).sorted { snapshot.nodes[$0].size(mode) > snapshot.nodes[$1].size(mode) }
            return [
                "folder": entryJSON(snapshot, id, mode: mode, total: total),
                "count": children.count,
                "items": children.prefix(limit).map { entryJSON(snapshot, $0, mode: mode, total: total) },
            ]
        },

        syncTool(
            "inventory_top",
            "The biggest files or folders anywhere under a folder of the scan. Every file is in the scan, so a single huge file deep inside shows up by name.",
            Schema.object(withScanProperties([
                "under": Schema.text("folder inside the scan (default the root)"),
                "kind": Schema.choice("files, folders or both (default files)", ["files", "folders", "both"]),
                "limit": Schema.integer("items to return (default 25, max 500)"),
                "mode": Schema.choice("size on disk or logical size (default allocated)", ["allocated", "logical"]),
            ]))
        ) { params in
            let scan = try scanArguments(params, store: store)
            let snapshot = scan.snapshot
            let id = try focus(params, in: scan)
            let mode = try sizeMode(params)
            let kind = try params.choice("kind", options: ["files", "folders", "both"], fallback: "files")
            let limit = try params.count("limit", fallback: 25, limit: 500)
            let ids = largest(snapshot, from: id, limit: limit, mode: mode) { node in
                kind == "both" || (kind == "folders") == node.isDirectory
            }
            let total = snapshot.nodes[id].size(mode)
            return ["under": snapshot.displayPath(of: id), "kind": kind, "items": ids.map { entryJSON(snapshot, $0, mode: mode, total: total) }]
        },

        syncTool(
            "inventory_kinds",
            "Space by file kind (video, disk images, Swift source, …) under a folder of the scan, like the Kinds panel of Disk Inventory, with the biggest file of each kind.",
            Schema.object(withScanProperties([
                "under": Schema.text("folder inside the scan (default the root)"),
                "limit": Schema.integer("kinds to return (default 20, max 200)"),
                "mode": Schema.choice("size on disk or logical size (default allocated)", ["allocated", "logical"]),
            ]))
        ) { params in
            let scan = try scanArguments(params, store: store)
            let snapshot = scan.snapshot
            let id = try focus(params, in: scan)
            let mode = try sizeMode(params)
            let limit = try params.count("limit", fallback: 20, limit: 200)
            var totals: [Int: (size: Int64, count: Int, biggest: Int)] = [:]
            subtree(snapshot, from: id) { child in
                let node = snapshot.nodes[child]
                guard !node.isDirectory else { return }
                let kind = Int(node.kind)
                var entry = totals[kind] ?? (0, 0, child)
                entry.size += node.size(mode)
                entry.count += 1
                if node.size(mode) > snapshot.nodes[entry.biggest].size(mode) { entry.biggest = child }
                totals[kind] = entry
            }
            let total = snapshot.nodes[id].size(mode)
            return [
                "under": snapshot.displayPath(of: id),
                "kinds": totals.sorted { $0.value.size > $1.value.size }.prefix(limit).map { kind, entry in
                    [
                        "kind": snapshot.kinds[kind].title,
                        "size": entry.size,
                        "size_h": human(entry.size),
                        "files": entry.count,
                        "share_percent": percent(entry.size, of: total),
                        "biggest": entryJSON(snapshot, entry.biggest, mode: mode, total: total),
                    ]
                },
            ]
        },

        syncTool(
            "inventory_search",
            "Find files in the scan by name, kind or path fragment, biggest first.",
            Schema.object(withScanProperties([
                "query": Schema.text("text to look for"),
                "field": Schema.choice("where to look (default all)", ["all", "name", "kind", "path"]),
                "limit": Schema.integer("matches to return (default 30, max 500)"),
                "mode": Schema.choice("size on disk or logical size (default allocated)", ["allocated", "logical"]),
            ]), required: ["query"])
        ) { params in
            let scan = try scanArguments(params, store: store)
            let snapshot = scan.snapshot
            let query = try params.requiredString("query")
            let field: SearchField = switch try params.choice("field", options: ["all", "name", "kind", "path"], fallback: "all") {
            case "name": .name
            case "kind": .kind
            case "path": .path
            default: .all
            }
            var options = ViewOptions()
            options.mode = try sizeMode(params)
            let limit = try params.count("limit", fallback: 30, limit: 500)
            let matches = try snapshot.search(query, field: field, kind: nil, options: options)
            let total = snapshot.nodes[0].size(options.mode)
            return ["found": matches.count, "items": matches.prefix(limit).map { entryJSON(snapshot, $0, mode: options.mode, total: total) }]
        },

        syncTool(
            "inventory_cleanup",
            "What can be removed, sorted by how safe it is: safe (caches, logs, Trash — apps recreate them), regenerable (build artifacts, package caches, Xcode data — rebuilt or downloaded again) and review (installers, local AI models, device backups, simulators — needs a look). Read-only: nothing is deleted.",
            Schema.object(withScanProperties([
                "safety": ["type": "array", "items": ["type": "string", "enum": ["safe", "regenerable", "review"]],
                           "description": "levels to include (default all)"],
                "limit": Schema.integer("items to list per category (default 8, max 200)"),
            ]))
        ) { params in
            let scan = try scanArguments(params, store: store)
            let snapshot = scan.snapshot
            let wanted = Set(params.list("safety"))
            let limit = try params.count("limit", fallback: 8, limit: 200)
            let groups = CleanupAnalyzer.analyze(snapshot).filter { wanted.isEmpty || wanted.contains($0.category.safety.rawValue) }
            var totals: [String: Int64] = [:]
            for group in groups { totals[group.category.safety.rawValue, default: 0] += group.size }
            return [
                "scan": scan.summary,
                "totals": totals.mapValues { ["size": $0, "size_h": human($0)] },
                "categories": groups.map { group in
                    [
                        "id": group.category.id,
                        "title": group.category.title,
                        "safety": group.category.safety.rawValue,
                        "why": group.category.explanation,
                        "size": group.size,
                        "size_h": human(group.size),
                        "items_count": group.items.count,
                        "items": group.items.prefix(limit).map { item in
                            ["path": snapshot.displayPath(of: item.node), "size": item.size, "size_h": human(item.size)]
                        },
                    ] as [String: Any]
                },
            ]
        },

        syncTool(
            "inventory_stale",
            "Big files in Desktop, Documents, Downloads, Movies, Music and Pictures that have not been opened or changed for a long time — candidates to move to iCloud Drive or Google Drive. The date is the latest of last opened (Spotlight), modified and added. Lists the cloud folders set up on this Mac. Read-only.",
            Schema.object(withScanProperties([
                "days": Schema.number("not touched for at least this many days (default 180)"),
                "min_size": Schema.size("smallest file to report (default 100M)"),
                "limit": Schema.integer("files to return (default 30, max 500)"),
            ]))
        ) { params in
            let scan = try scanArguments(params, store: store)
            let days = min(max(try params.number("days") ?? 180, 1), 3650)
            let minSize = try sizeArgument(params, "min_size", fallback: 100 << 20)
            let limit = try params.count("limit", fallback: 30, limit: 500)
            let stale = CloudOffload.staleFiles(in: scan.snapshot, minSize: minSize, olderThanDays: days)
            let total = stale.reduce(Int64(0)) { $0 + $1.size }
            let inICloud = stale.filter(\.isInICloud).reduce(Int64(0)) { $0 + $1.size }
            return [
                "days": days,
                "min_size": minSize,
                "found": stale.count,
                "total_size": total,
                "total_size_h": human(total),
                "already_in_icloud_size_h": human(inICloud),
                "cloud_destinations": CloudOffload.destinations().map { ["service": $0.service.rawValue, "title": $0.title, "root": $0.root.path] },
                "files": stale.prefix(limit).map { file in
                    [
                        "path": file.path,
                        "size": file.size,
                        "size_h": human(file.size),
                        "last_activity": file.lastActivity.map { formatterISO.string(from: $0) } as Any,
                        "last_opened": file.lastUsed.map { formatterISO.string(from: $0) } as Any,
                        "in_icloud": file.isInICloud,
                    ]
                },
            ]
        },
    ]
}
