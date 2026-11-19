import Darwin
import Foundation

enum BulkScan {
    private struct Metadata {
        let device: Int32
        let inode: UInt64
        let directory: Bool
        let symlink: Bool
        let regular: Bool
        let hardLink: Bool
        let logical: Int64
        let allocated: Int64

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            let type = info.st_mode & S_IFMT
            directory = type == S_IFDIR
            symlink = type == S_IFLNK
            regular = type == S_IFREG
            hardLink = regular && info.st_nlink > 1
            logical = directory ? 0 : max(0, info.st_size)
            allocated = directory ? 0 : max(0, info.st_blocks) * 512
        }

        init(device: Int32, inode: UInt64, type: UInt32, links: UInt32, logical: Int64, allocated: Int64) {
            self.device = device
            self.inode = inode
            directory = type == VDIR.rawValue
            symlink = type == VLNK.rawValue
            regular = type == VREG.rawValue
            hardLink = regular && links > 1
            self.logical = max(0, logical)
            self.allocated = max(0, allocated)
        }
    }

    private enum BatchError: Error { case unsupported }

    private struct Record {
        let bytes: UnsafeRawBufferPointer
        var offset = 0

        mutating func take<T>(_ type: T.Type) throws -> T {
            guard offset <= bytes.count - MemoryLayout<T>.size else { throw BatchError.unsupported }
            let value = bytes.loadUnaligned(fromByteOffset: offset, as: type)
            offset += MemoryLayout<T>.size
            return value
        }
    }

    static func scan(
        root: URL, rootInfo: stat, ignoreCreatorCode: Bool, progress: (ScanProgress) -> Void
    ) throws -> ScanSummary? {
        do {
            return try scanAPFS(root: root, rootInfo: rootInfo, ignoreCreatorCode: ignoreCreatorCode, progress: progress)
        } catch BatchError.unsupported {
            return nil
        }
    }

    private static func scanAPFS(
        root: URL, rootInfo: stat, ignoreCreatorCode: Bool, progress: (ScanProgress) -> Void
    ) throws -> ScanSummary {
        let rootPath = root.path
        let descriptor = rootPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw ScanError.filesystem(rootPath, errno) }
        defer { close(descriptor) }
        var actualRoot = stat()
        guard fstat(descriptor, &actualRoot) == 0, actualRoot.st_dev == rootInfo.st_dev, actualRoot.st_ino == rootInfo.st_ino else {
            throw BatchError.unsupported
        }
        var fs = statfs()
        guard fstatfs(descriptor, &fs) == 0,
              withUnsafeBytes(of: fs.f_fstypename, { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }) == "apfs"
        else { throw BatchError.unsupported }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        let common = UInt32(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID | ATTR_CMN_DEVID | ATTR_CMN_FLAGS)
        let file = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)
        attributes.commonattr = common | UInt32(ATTR_CMN_ERROR) | ATTR_CMN_RETURNED_ATTRS
        if !ignoreCreatorCode {
            attributes.commonattr |= UInt32(ATTR_CMN_FNDRINFO | ATTR_CMN_ACCESSMASK)
        }
        attributes.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
        attributes.fileattr = file
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 8)
        defer { buffer.deallocate() }

        var catalog = KindCatalog()
        var seenLinks = Set<Inode>()
        var issues: [ScanIssue] = []
        var issueCount = 0
        let rootName = root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent
        let rootKind = catalog.kind(name: rootName, directory: true, symlink: false, alias: false)
        var nodes = [FileNode(
            name: rootName, parent: -1, kind: rootKind, device: rootInfo.st_dev, inode: rootInfo.st_ino,
            isDirectory: true, logical: 0, allocated: 0, rawAllocated: 0, isHardLink: false
        )]
        var nextProgress = ContinuousClock.now

        func report(_ path: @autoclosure () -> String, _ code: Int32) {
            issueCount += 1
            if issues.count < 250 {
                issues.append(ScanIssue(path: path(), message: String(cString: strerror(code))))
            }
        }

        func path(for id: Int) -> String {
            var parts: [String] = []
            var index = id
            while index > 0 {
                parts.append(nodes[index].name)
                index = Int(nodes[index].parent)
            }
            return id == 0 ? rootPath : (rootPath == "/" ? rootPath : rootPath + "/") + parts.reversed().joined(separator: "/")
        }

        func enumerate(_ fd: Int32, parent: Int) throws {
            while true {
                try Task.checkCancellation()
                if ContinuousClock.now >= nextProgress {
                    progress(ScanProgress(entries: nodes.count, path: path(for: parent), traversal: .bulk))
                    nextProgress = .now + .milliseconds(125)
                }
                let count = getattrlistbulk(fd, &attributes, buffer.baseAddress, buffer.count, UInt64(FSOPT_RETURN_REALDEV))
                if count == 0 { return }
                if count < 0 {
                    let code = errno
                    if code == EACCES || code == EPERM {
                        if parent == 0 { throw ScanError.filesystem(rootPath, code) }
                        report(path(for: parent), code)
                        return
                    }
                    throw BatchError.unsupported
                }

                var position = 0
                for _ in 0..<count {
                    guard position <= buffer.count - MemoryLayout<UInt32>.size else { throw BatchError.unsupported }
                    let size = Int(buffer.loadUnaligned(fromByteOffset: position, as: UInt32.self))
                    guard size >= 24, size <= buffer.count - position else { throw BatchError.unsupported }
                    let bytes = UnsafeRawBufferPointer(rebasing: buffer[position..<(position + size)])
                    position += size
                    var record = Record(bytes: bytes, offset: MemoryLayout<UInt32>.size)
                    let returned = try record.take(attribute_set_t.self)
                    let errorCode = returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0
                        ? Int32(bitPattern: try record.take(UInt32.self)) : 0
                    guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { throw BatchError.unsupported }
                    let nameReferenceOffset = record.offset
                    let reference = try record.take(attrreference_t.self)
                    let start = nameReferenceOffset + Int(reference.attr_dataoffset)
                    let length = Int(reference.attr_length)
                    guard start >= record.offset, length > 0, start <= size - length,
                          bytes[start + length - 1] == 0 else { throw BatchError.unsupported }
                    let namePointer = buffer.baseAddress!.advanced(by: position - size + start).assumingMemoryBound(to: CChar.self)
                    guard let name = String(validatingCString: namePointer) else {
                        report(path(for: parent), EILSEQ)
                        continue
                    }
                    let device = returned.commonattr & UInt32(ATTR_CMN_DEVID) != 0 ? try record.take(Int32.self) : -1
                    let type = returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 ? try record.take(UInt32.self) : 0
                    var finder = FinderInfo()
                    if returned.commonattr & UInt32(ATTR_CMN_FNDRINFO) != 0 {
                        guard record.offset <= bytes.count - 32 else { throw BatchError.unsupported }
                        finder = FinderInfo(bytes: UnsafeRawBufferPointer(rebasing: bytes[record.offset..<(record.offset + 32)]))
                        record.offset += 32
                    }
                    var mode = returned.commonattr & UInt32(ATTR_CMN_ACCESSMASK) != 0 ? try record.take(UInt32.self) : 0
                    let flags = returned.commonattr & UInt32(ATTR_CMN_FLAGS) != 0 ? try record.take(UInt32.self) : 0
                    let inode = returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0 ? try record.take(UInt64.self) : 0
                    let mount = returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 ? try record.take(UInt32.self) : 0
                    let metadata: Metadata
                    if errorCode == 0, returned.commonattr & common == common, device != -1,
                       flags & UInt32(SF_FIRMLINK) == 0, mount & UInt32(DIR_MNTSTATUS_MNTPOINT) == 0,
                       (type == VDIR.rawValue && returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0)
                       || (type == VREG.rawValue && returned.fileattr & file == file) {
                        if type == VDIR.rawValue {
                            metadata = Metadata(device: device, inode: inode, type: type, links: 0, logical: 0, allocated: 0)
                        } else {
                            let links = try record.take(UInt32.self)
                            let allocated = try record.take(Int64.self)
                            let logical = try record.take(Int64.self)
                            metadata = Metadata(device: device, inode: inode, type: type, links: links, logical: logical, allocated: allocated)
                        }
                    } else {
                        var info = stat()
                        guard fstatat(fd, namePointer, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                            report(path(for: parent) + "/" + name, errno)
                            continue
                        }
                        metadata = Metadata(info)
                        mode = UInt32(info.st_mode)
                    }
                    guard metadata.device == rootInfo.st_dev else { continue }
                    guard nodes.count < Int32.max else { throw ScanError.tooManyEntries }
                    let id = nodes.count
                    let kind: Int32
                    if !ignoreCreatorCode, !metadata.symlink {
                        kind = catalog.finderKind(name: name, directory: metadata.directory, mode: mode, info: finder,
                                                  path: (parent == 0 && rootPath == "/" ? "" : path(for: parent)) + "/" + name)
                    } else {
                        kind = catalog.kind(name: name, directory: metadata.directory, symlink: metadata.symlink,
                                            alias: metadata.regular && name.hasSuffix(".alias"))
                    }
                    let identity = Inode(device: metadata.device, number: metadata.inode)
                    let countBlocks = !metadata.hardLink || seenLinks.insert(identity).inserted
                    nodes.append(FileNode(
                        name: name, parent: Int32(parent), kind: kind, device: metadata.device, inode: metadata.inode,
                        isDirectory: metadata.directory, nextSibling: nodes[parent].firstChild,
                        logical: metadata.logical, allocated: countBlocks ? metadata.allocated : 0,
                        rawAllocated: metadata.allocated, isHardLink: metadata.hardLink, fileCount: metadata.directory ? 0 : 1
                    ))
                    nodes[parent].firstChild = Int32(id)
                }
            }
        }

        struct Frame {
            // Descriptors are kept for the active ancestry only, so openat avoids repeating ancestor lookups.
            let fd: Int32
            var child: Int32
        }
        try enumerate(descriptor, parent: 0)
        var frames = [Frame(fd: descriptor, child: nodes[0].firstChild)]
        defer {
            for frame in frames.dropFirst() where frame.fd >= 0 { close(frame.fd) }
        }
        while let frame = frames.last {
            if frame.child < 0 {
                if frames.count > 1, frame.fd >= 0 { close(frame.fd) }
                frames.removeLast()
                continue
            }
            let id = Int(frame.child)
            let node = nodes[id]
            frames[frames.count - 1].child = node.nextSibling
            guard node.isDirectory else { continue }
            try Task.checkCancellation()
            let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            let fd = frame.fd >= 0
                ? node.name.withCString { openat(frame.fd, $0, flags) }
                : path(for: id).withCString { open($0, flags) }
            guard fd >= 0 else {
                let code = errno
                if code == EMFILE || code == ENFILE || code == ENAMETOOLONG { throw BatchError.unsupported }
                report(path(for: id), code)
                continue
            }
            var identity = stat()
            guard fstat(fd, &identity) == 0, identity.st_dev == node.device, identity.st_ino == node.inode else {
                close(fd)
                report(path(for: id), ESTALE)
                continue
            }
            do {
                try enumerate(fd, parent: id)
            } catch {
                close(fd)
                throw error
            }
            if frames.count < 32 {
                frames.append(Frame(fd: fd, child: nodes[id].firstChild))
            } else {
                close(fd)
                frames.append(Frame(fd: -1, child: nodes[id].firstChild))
            }
        }
        progress(ScanProgress(entries: nodes.count, path: rootPath, traversal: .bulk, finishing: true))
        for id in nodes.indices.reversed() where id > 0 {
            if id.isMultiple(of: 1024) { try Task.checkCancellation() }
            let parent = Int(nodes[id].parent)
            nodes[parent].logical += nodes[id].logical
            nodes[parent].allocated += nodes[id].allocated
            nodes[parent].fileCount += nodes[id].fileCount
        }
        let volume = (try? root.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true ? VolumeUsage.read(root) : nil
        return ScanSummary(root: root, nodes: nodes, kinds: catalog.kinds, issues: issues, issueCount: issueCount,
                           volume: volume, ignoreCreatorCode: ignoreCreatorCode, traversal: .bulk)
    }
}
