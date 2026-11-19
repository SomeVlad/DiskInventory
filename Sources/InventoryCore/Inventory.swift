import Darwin
import Foundation
import UniformTypeIdentifiers

public enum SizeMode: String, Sendable {
    case allocated, logical
}

public struct FileKind: Hashable, Sendable {
    public let identifier: String
    public let title: String
    public let isPackage: Bool
}

public struct FileNode: Sendable {
    public let name: String
    public var parent: Int32
    public var kind: Int32
    public let device: Int32
    var references: UInt32 = 0
    public let inode: UInt64
    public let isDirectory: Bool
    public var firstChild: Int32 = -1
    public var nextSibling: Int32 = -1
    public var logical: Int64
    public var allocated: Int64
    let rawAllocated: Int64
    let shared: UInt64
    public var fileCount: Int = 0

    var isShared: Bool { shared != 0 }
    var identity: UInt64 { isShared ? shared : inode }

    public func size(_ mode: SizeMode) -> Int64 {
        mode == .allocated ? allocated : logical
    }
}

public struct VolumeUsage: Sendable {
    public let capacity: Int64
    public let free: Int64

    public static func read(_ url: URL) -> Self? {
        var info = statfs()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { statfs($0, &info) } ?? -1
        }) == 0 else { return nil }
        return Self(
            capacity: Int64(clamping: info.f_blocks) * Int64(info.f_bsize),
            free: Int64(clamping: info.f_bfree) * Int64(info.f_bsize)
        )
    }
}

public struct ScanIssue: Sendable {
    public let path: String
    public let message: String
}

public struct ScanProgress: Sendable {
    public let entries: Int
    public let path: String
    public let traversal: ScanTraversal
    public var finishing = false
    public var bytes: Int64 = 0
}

public enum ScanTraversal: String, Sendable {
    case bulk, fts
}

public struct ScanSummary: Sendable {
    public let root: URL
    public let nodes: [FileNode]
    public let kinds: [FileKind]
    public let issues: [ScanIssue]
    public let issueCount: Int
    public let volume: VolumeUsage?
    let ignoreCreatorCode: Bool
    public let traversal: ScanTraversal

    public func children(of parent: Int) -> [Int] {
        var result: [Int] = []
        var child = nodes[parent].firstChild
        while child >= 0 {
            result.append(Int(child))
            child = nodes[Int(child)].nextSibling
        }
        return result
    }

    public func lineage(of id: Int) -> [Int] {
        var lineage = [id]
        var parent = nodes[id].parent
        while parent >= 0 {
            lineage.append(Int(parent))
            parent = nodes[Int(parent)].parent
        }
        return lineage.reversed()
    }

    public func url(for id: Int) -> URL {
        lineage(of: id).dropFirst().reduce(root) { url, child in
            url.appending(path: nodes[child].name, directoryHint: nodes[child].isDirectory ? .isDirectory : .notDirectory)
        }
    }

    public func find(_ url: URL) -> Int? {
        let base = root.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.starts(with: base) else { return nil }
        var node = 0
        for component in target.dropFirst(base.count) {
            var child = nodes[node].firstChild
            while child >= 0, nodes[Int(child)].name != component {
                child = nodes[Int(child)].nextSibling
            }
            guard child >= 0 else { return nil }
            node = Int(child)
        }
        return node
    }
}

public enum ScanError: LocalizedError {
    case filesystem(String, Int32)
    case tooManyEntries

    public var errorDescription: String? {
        switch self {
        case let .filesystem(path, code):
            "\(path): \(String(cString: strerror(code)))"
        case .tooManyEntries:
            "This location contains too many entries to index in one window."
        }
    }
}

struct Inode: Hashable {
    let device: Int32
    let number: UInt64
}

struct FinderInfo {
    // The first eight bytes are file type and creator for files, window bounds for folders.
    var typeAndCreator: UInt64 = 0
    var flags: UInt16 = 0

    var isAlias: Bool { flags & 0x8000 != 0 }
    var hasBundle: Bool { flags & 0x2000 != 0 }

    init() {}

    init(bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= 32 else { return }
        typeAndCreator = bytes.loadUnaligned(as: UInt64.self)
        flags = UInt16(bigEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
    }

    static func read(_ path: UnsafePointer<CChar>) -> FinderInfo {
        withUnsafeTemporaryAllocation(byteCount: 32, alignment: 8) { buffer in
            let length = getxattr(path, "com.apple.FinderInfo", buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
            guard length == buffer.count else { return FinderInfo() }
            return FinderInfo(bytes: UnsafeRawBufferPointer(buffer))
        }
    }
}

struct KindCatalog {
    private struct FinderKey: Hashable {
        let suffix: String
        let directory: Bool
        let executable: Bool
        let typeAndCreator: UInt64
        let bundle: Bool
    }

    var kinds = [
        FileKind(identifier: "public.folder", title: "Folder", isPackage: false),
        FileKind(identifier: "public.symlink", title: "Symbolic Link", isPackage: false),
        FileKind(identifier: "public.data", title: "File", isPackage: false),
        FileKind(identifier: "com.apple.alias-file", title: "Alias", isPackage: false)
    ]
    private var byExtension: [String: Int32] = [:]
    private var byIdentifier: [String: Int32] = [
        "public.folder": 0, "public.symlink": 1, "public.data": 2, "com.apple.alias-file": 3
    ]
    private var byKind: [FileKind: Int32] = [:]
    private var byFinderKey: [FinderKey: Int32] = [:]
    private static let finderKeys: Set<URLResourceKey> = [.isAliasFileKey, .isPackageKey, .localizedTypeDescriptionKey, .contentTypeKey]

    mutating func finderKind(
        name: String, directory: Bool, mode: UInt32, info: FinderInfo, path: @autoclosure () -> String
    ) -> Int32 {
        if !directory, info.isAlias { return 3 }
        let suffix = Self.suffix(of: name)
        if directory, suffix.isEmpty, !info.hasBundle { return 0 }
        let key = FinderKey(suffix: suffix, directory: directory, executable: !directory && mode & 0o111 != 0,
                            typeAndCreator: directory ? 0 : info.typeAndCreator, bundle: info.hasBundle)
        if let id = byFinderKey[key] { return id }
        let values = autoreleasepool {
            try? URL(filePath: path(), directoryHint: directory ? .isDirectory : .notDirectory)
                .resourceValues(forKeys: Self.finderKeys)
        }
        if values?.isAliasFile == true { return 3 }
        let id = values.flatMap { metadataKind($0, directory: directory) }
            ?? kind(name: name, directory: directory, symlink: false, alias: false)
        byFinderKey[key] = id
        return id
    }

    private static func suffix(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    private mutating func metadataKind(_ values: URLResourceValues, directory: Bool) -> Int32? {
        if directory, values.isPackage != true { return 0 }
        guard let title = values.localizedTypeDescription, !title.isEmpty else { return nil }
        let identifier = values.contentType?.identifier ?? (directory ? "public.package" : "public.data")
        let kind = FileKind(identifier: identifier + "|" + title, title: title, isPackage: directory)
        if let id = byKind[kind] { return id }
        let id = Int32(kinds.count)
        kinds.append(kind)
        byKind[kind] = id
        return id
    }

    mutating func kind(name: String, directory: Bool, symlink: Bool, alias: Bool) -> Int32 {
        if symlink { return 1 }
        if alias { return 3 }
        let ext = Self.suffix(of: name)
        guard !ext.isEmpty else { return directory ? 0 : 2 }
        let key = directory ? "." + ext : ext
        if let id = byExtension[key] { return id }
        let type = directory ? UTType(filenameExtension: ext, conformingTo: .directory) : UTType(filenameExtension: ext)
        let inferredPackage = directory && ["app", "bundle", "framework", "pkg", "plugin", "appex", "photoslibrary", "xcodeproj", "rtfd", "playground"].contains(ext)
        if directory, !inferredPackage, type?.conforms(to: .package) != true {
            byExtension[key] = 0
            return 0
        }
        let identifier = type.flatMap { $0.isDynamic ? nil : $0.identifier } ?? key
        let identity = directory ? "." + identifier : identifier
        if let existing = byIdentifier[identity] {
            byExtension[key] = existing
            return existing
        }
        let id = Int32(kinds.count)
        kinds.append(FileKind(
            identifier: identifier,
            title: type?.localizedDescription ?? "\(ext.uppercased()) \(directory ? "Package" : "File")",
            isPackage: directory
        ))
        byIdentifier[identity] = id
        byExtension[key] = id
        return id
    }
}

public enum InventoryScanner {
    public static func scan(
        _ location: URL,
        ignoreCreatorCode: Bool = true,
        preferBulk: Bool = true,
        progress: (ScanProgress) -> Void = { _ in }
    ) throws -> ScanSummary {
        try scan(location, directoryOnly: true, ignoreCreatorCode: ignoreCreatorCode, preferBulk: preferBulk, progress: progress)
    }

    private static func scan(
        _ location: URL,
        directoryOnly: Bool,
        ignoreCreatorCode: Bool,
        preferBulk: Bool = true,
        progress: (ScanProgress) -> Void
    ) throws -> ScanSummary {
        let normalized = location.standardizedFileURL
        let root = directoryOnly ? normalized.resolvingSymlinksInPath()
            : normalized.deletingLastPathComponent().resolvingSymlinksInPath()
                .appending(path: normalized.lastPathComponent, directoryHint: .notDirectory)
        var rootInfo = stat()
        let status = root.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &rootInfo) } ?? -1
        }
        guard status == 0 else { throw ScanError.filesystem(root.path, errno) }
        guard !directoryOnly || rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw ScanError.filesystem(root.path, ENOTDIR)
        }

        if preferBulk, rootInfo.st_mode & S_IFMT == S_IFDIR,
           let bulk = try BulkScan.scan(root: root, rootInfo: rootInfo, ignoreCreatorCode: ignoreCreatorCode, progress: progress) {
            return bulk
        }

        guard let path = root.withUnsafeFileSystemRepresentation({ $0.flatMap { strdup($0) } }) else {
            throw ScanError.filesystem(root.path, ENOMEM)
        }
        defer { free(path) }
        var paths: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let traversal = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw ScanError.filesystem(root.path, errno)
        }
        defer { fts_close(traversal) }

        // fts_number is caller-owned storage on each live directory entry.
        var nodes: [FileNode] = []
        var catalog = KindCatalog()
        var links = Set<Inode>()
        var issues: [ScanIssue] = []
        var issueCount = 0
        var nextProgress = ContinuousClock.now

        func recordIssue(_ path: @autoclosure () -> String, _ code: Int32) {
            issueCount += 1
            if issues.count < 250 {
                issues.append(ScanIssue(path: path(), message: String(cString: strerror(code))))
            }
        }

        while true {
            errno = 0
            guard let entry = fts_read(traversal) else {
                let code = errno
                if code != 0 { recordIssue(root.path, code) }
                break
            }
            try Task.checkCancellation()
            let level = Int(entry.pointee.fts_level)
            let info = Int32(entry.pointee.fts_info)

            switch info {
            case FTS_DP:
                let id = entry.pointee.fts_number - 1
                let parent = id >= 0 ? nodes[id].parent : -1
                if parent >= 0 {
                    nodes[Int(parent)].logical += nodes[id].logical
                    nodes[Int(parent)].allocated += nodes[id].allocated
                    nodes[Int(parent)].fileCount += nodes[id].fileCount
                }
                continue
            case FTS_DNR, FTS_ERR, FTS_NS, FTS_DC:
                let code = entry.pointee.fts_errno == 0 ? EIO : entry.pointee.fts_errno
                if level == 0 { throw ScanError.filesystem(root.path, code) }
                recordIssue(String(cString: entry.pointee.fts_path), code)
                continue
            default:
                break
            }
            guard let attributes = entry.pointee.fts_statp?.pointee else { continue }
            let directory = info == FTS_D
            if level > 0, attributes.st_dev != rootInfo.st_dev {
                if directory { fts_set(traversal, entry, FTS_SKIP) }
                continue
            }
            guard nodes.count < Int32.max else { throw ScanError.tooManyEntries }
            let name = withUnsafePointer(to: &entry.pointee.fts_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.fts_namelen) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard level == 0 || name != nil else {
                recordIssue(String(cString: entry.pointee.fts_path), EILSEQ)
                if directory { fts_set(traversal, entry, FTS_SKIP) }
                continue
            }
            let parent = level == 0 ? -1 : entry.pointee.fts_parent.pointee.fts_number - 1
            let id = nodes.count
            let symlink = info == FTS_SL || info == FTS_SLNONE
            let regular = attributes.st_mode & S_IFMT == S_IFREG
            let displayName = level == 0 && root.lastPathComponent.isEmpty ? "/" : name ?? root.lastPathComponent
            let kind: Int32
            if !ignoreCreatorCode, !symlink, level > 0 {
                let finder = FinderInfo.read(entry.pointee.fts_path)
                kind = catalog.finderKind(name: displayName, directory: directory, mode: UInt32(attributes.st_mode),
                                          info: finder, path: String(cString: entry.pointee.fts_path))
            } else {
                let alias = regular && displayName.hasSuffix(".alias")
                kind = catalog.kind(name: displayName, directory: directory, symlink: symlink, alias: alias)
            }
            let identity = Inode(device: attributes.st_dev, number: attributes.st_ino)
            let isHardLink = regular && attributes.st_nlink > 1
            let countBlocks = !isHardLink || links.insert(identity).inserted
            let logical = directory ? 0 : max(0, attributes.st_size)
            let rawAllocated = directory ? 0 : max(0, attributes.st_blocks) * 512
            let allocated = countBlocks ? rawAllocated : 0
            var node = FileNode(
                name: displayName, parent: Int32(parent), kind: kind, device: attributes.st_dev, inode: attributes.st_ino,
                isDirectory: directory, logical: logical, allocated: allocated,
                rawAllocated: rawAllocated, shared: isHardLink ? attributes.st_ino : 0, fileCount: directory ? 0 : 1
            )
            if parent >= 0 {
                node.nextSibling = nodes[parent].firstChild
                nodes[parent].firstChild = Int32(id)
                if !directory {
                    nodes[parent].logical += logical
                    nodes[parent].allocated += allocated
                    nodes[parent].fileCount += 1
                }
            }
            nodes.append(node)
            entry.pointee.fts_number = id + 1

            if id.isMultiple(of: 256), ContinuousClock.now >= nextProgress {
                progress(ScanProgress(entries: id + 1, path: String(cString: entry.pointee.fts_path), traversal: .fts))
                nextProgress = .now + .milliseconds(125)
            }
        }
        guard !nodes.isEmpty else { throw ScanError.filesystem(root.path, EIO) }
        try Task.checkCancellation()
        let volume = (try? root.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true ? VolumeUsage.read(root) : nil
        return ScanSummary(root: root, nodes: nodes, kinds: catalog.kinds, issues: issues, issueCount: issueCount, volume: volume, ignoreCreatorCode: ignoreCreatorCode, traversal: .fts)
    }


    public static func refresh(
        _ id: Int,
        in previous: ScanSummary,
        progress: (ScanProgress) -> Void = { _ in }
    ) throws -> ScanSummary {
        guard id > 0, previous.nodes.indices.contains(id), previous.issueCount == previous.issues.count else {
            return try scan(previous.root, ignoreCreatorCode: previous.ignoreCreatorCode, progress: progress)
        }
        let target = previous.url(for: id)
        let parent = target.deletingLastPathComponent().standardizedFileURL
        guard parent.resolvingSymlinksInPath().pathComponents == parent.pathComponents else {
            return try scan(previous.root, ignoreCreatorCode: previous.ignoreCreatorCode, progress: progress)
        }
        let replacement: ScanSummary?
        do {
            replacement = try scan(target, directoryOnly: false, ignoreCreatorCode: previous.ignoreCreatorCode, progress: progress)
        } catch ScanError.filesystem(_, ENOENT) {
            replacement = nil
        } catch ScanError.filesystem(_, ENOTDIR) {
            return try scan(previous.root, ignoreCreatorCode: previous.ignoreCreatorCode, progress: progress)
        }
        if let replacement, replacement.nodes[0].device != previous.nodes[0].device {
            return try scan(previous.root, ignoreCreatorCode: previous.ignoreCreatorCode, progress: progress)
        }

        return try replacing(id, in: previous, with: replacement)
    }

    public static func removing(_ id: Int, from previous: ScanSummary) throws -> ScanSummary {
        guard id > 0, previous.nodes.indices.contains(id) else { return previous }
        let item = previous.nodes[id]
        guard !item.isDirectory, !item.isShared else {
            return try replacing(id, in: previous, with: nil)
        }
        try Task.checkCancellation()
        let parent = Int(item.parent)
        guard parent >= 0 else { return previous }

        var nodes = previous.nodes
        if nodes[parent].firstChild == id {
            nodes[parent].firstChild = item.nextSibling
        } else {
            var sibling = nodes[parent].firstChild
            while sibling >= 0, nodes[Int(sibling)].nextSibling != id {
                sibling = nodes[Int(sibling)].nextSibling
            }
            guard sibling >= 0 else { return previous }
            nodes[Int(sibling)].nextSibling = item.nextSibling
        }
        nodes[id] = FileNode(name: "", parent: -1, kind: 0, device: 0, inode: 0, isDirectory: false,
                             logical: 0, allocated: 0, rawAllocated: 0, shared: 0)
        var ancestor = parent
        while ancestor >= 0 {
            nodes[ancestor].logical -= item.logical
            nodes[ancestor].allocated -= item.allocated
            nodes[ancestor].fileCount -= item.fileCount
            ancestor = Int(nodes[ancestor].parent)
        }
        let path = previous.url(for: id).path
        let issues = previous.issues.filter { $0.path != path }
        let issueCount = previous.issueCount - (previous.issues.count - issues.count)
        let volume = previous.volume == nil ? nil : VolumeUsage.read(previous.root)
        return ScanSummary(root: previous.root, nodes: nodes, kinds: previous.kinds, issues: issues,
                           issueCount: issueCount, volume: volume, ignoreCreatorCode: previous.ignoreCreatorCode,
                           traversal: previous.traversal)
    }

    private static func replacing(_ id: Int, in previous: ScanSummary, with replacement: ScanSummary?) throws -> ScanSummary {
        var kinds = previous.kinds
        var kindIndex = Dictionary(uniqueKeysWithValues: kinds.enumerated().map { ($1, Int32($0)) })
        let newKinds = (replacement?.kinds ?? []).map { kind in
            if let index = kindIndex[kind] { return index }
            let index = Int32(kinds.count)
            kinds.append(kind)
            kindIndex[kind] = index
            return index
        }
        struct Entry {
            let source: Int
            let parent: Int32
            let replacement: Bool
        }
        var work = [Entry(source: 0, parent: -1, replacement: false)]
        var nodes: [FileNode] = []
        nodes.reserveCapacity(previous.nodes.count)
        var linked = Set<Inode>()
        var possibleLinks = Set<Inode>()
        for group in [previous.nodes, replacement?.nodes ?? []] {
            for node in group where node.isShared {
                possibleLinks.insert(Inode(device: node.device, number: node.shared))
            }
        }
        while let entry = work.popLast() {
            if nodes.count.isMultiple(of: 1024) { try Task.checkCancellation() }
            let source = entry.replacement ? (replacement?.nodes ?? []) : previous.nodes
            let item = source[entry.source]
            if item.nextSibling >= 0, !entry.replacement || entry.source != 0 {
                work.append(Entry(source: Int(item.nextSibling), parent: entry.parent, replacement: entry.replacement))
            }
            if !entry.replacement, entry.source == id {
                guard replacement != nil else { continue }
                work.append(Entry(source: 0, parent: entry.parent, replacement: true))
                continue
            }
            guard nodes.count < Int32.max else { throw ScanError.tooManyEntries }
            var node = item
            let index = Int32(nodes.count)
            if entry.replacement { node.kind = newKinds[Int(node.kind)] }
            node.parent = entry.parent
            node.firstChild = -1
            node.nextSibling = -1
            if node.isDirectory {
                node.logical = 0
                node.allocated = 0
                node.fileCount = 0
            } else {
                let identity = Inode(device: node.device, number: node.identity)
                let count = !possibleLinks.contains(identity) || linked.insert(identity).inserted
                node.allocated = count ? node.rawAllocated : 0
            }
            if entry.parent >= 0 {
                node.nextSibling = nodes[Int(entry.parent)].firstChild
                nodes[Int(entry.parent)].firstChild = index
            }
            nodes.append(node)
            if item.firstChild >= 0 {
                work.append(Entry(source: Int(item.firstChild), parent: index, replacement: entry.replacement))
            }
        }
        for i in nodes.indices.reversed() {
            if i.isMultiple(of: 1024) { try Task.checkCancellation() }
            let parent = nodes[i].parent
            if parent >= 0 {
                nodes[Int(parent)].logical += nodes[i].logical
                nodes[Int(parent)].allocated += nodes[i].allocated
                nodes[Int(parent)].fileCount += nodes[i].fileCount
            }
        }
        let path = previous.url(for: id).path
        let outside = previous.issues.filter { $0.path != path && !$0.path.hasPrefix(path + "/") }
        let issueCount = previous.issueCount - (previous.issues.count - outside.count) + (replacement?.issueCount ?? 0)
        let issues = outside + (replacement?.issues ?? [])
        let volume = previous.volume == nil ? nil : VolumeUsage.read(previous.root)
        return ScanSummary(root: previous.root, nodes: nodes, kinds: kinds, issues: Array(issues.prefix(250)), issueCount: issueCount, volume: volume, ignoreCreatorCode: previous.ignoreCreatorCode, traversal: previous.traversal)
    }
}
