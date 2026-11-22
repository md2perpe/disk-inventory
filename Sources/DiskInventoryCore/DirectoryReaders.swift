import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One entry of a directory as reported by the file system.
struct RawEntry {
    enum Kind: UInt8 {
        case file, directory, symlink, other
    }

    var name: String
    var kind: Kind
    /// bytes in the file (including the resource fork on macOS); 0 for directories
    var logicalSize: UInt64
    /// bytes allocated on disk; 0 for directories
    var physicalSize: UInt64
    /// the volume the entry is on
    var device: UInt64
    /// a directory that is the root of another mounted volume
    var isMountPoint: Bool
    var isExecutable: Bool
}

enum DirectoryReadError: Error {
    /// the file system doesn't support this way of reading directories (try another reader)
    case unsupported
    case failed(errno: Int32)
}

/// Lists a directory together with the attributes needed for the disk usage tree.
protocol DirectoryReader {
    /// - Parameter parentDevice: the volume the directory is on (used to recognise mount points)
    func readEntries(atPath path: String, parentDevice: UInt64) throws -> [RawEntry]
}

// MARK: - Portable implementation: readdir + lstat

/// Works everywhere. Needs one `lstat` per entry, but no Foundation objects.
struct POSIXDirectoryReader: DirectoryReader {
    func readEntries(atPath path: String, parentDevice: UInt64) throws -> [RawEntry] {
        guard let dir = opendir(path) else { throw DirectoryReadError.failed(errno: errno) }
        defer { closedir(dir) }
        let fd = dirfd(dir)

        var entries: [RawEntry] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }

            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }

            let type = UInt32(st.st_mode) & 0o170000
            let kind: RawEntry.Kind
            switch type {
            case 0o040000: kind = .directory
            case 0o120000: kind = .symlink
            case 0o100000: kind = .file
            default: kind = .other
            }
            let device = UInt64(st.st_dev)
            let hasSize = kind != .directory
            entries.append(RawEntry(
                name: name,
                kind: kind,
                logicalSize: hasSize ? UInt64(max(0, Int(st.st_size))) : 0,
                physicalSize: hasSize ? UInt64(max(0, Int(st.st_blocks))) * 512 : 0,
                device: device,
                isMountPoint: kind == .directory && device != parentDevice,
                isExecutable: st.st_mode & 0o111 != 0))
        }
        return entries
    }
}

// MARK: - macOS: getattrlistbulk

#if canImport(Darwin)

/// Reads whole directories with a single `getattrlistbulk` call per buffer full of entries (the call
/// Foundation uses internally), without creating a `URL` or a dictionary per file.
///
/// It asks for the same attributes as the Foundation resource keys `totalFileSize` and
/// `totalFileAllocatedSize`, so sizes include resource forks and compressed files are accounted correctly
/// (which `st_blocks` of `lstat` would not do).
struct BulkDirectoryReader: DirectoryReader {
    private static let bufferSize = 128 * 1024

    func readEntries(atPath path: String, parentDevice: UInt64) throws -> [RawEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw DirectoryReadError.failed(errno: errno) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_ACCESSMASK)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        let options = UInt64(truncatingIfNeeded: FSOPT_PACK_INVAL_ATTRS)
        var entries: [RawEntry] = []

        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, options)
            if count < 0 {
                let error = errno
                // e.g. network volumes and some other file systems can't do this
                if error == ENOTSUP || error == EINVAL || error == ENOSYS { throw DirectoryReadError.unsupported }
                throw DirectoryReadError.failed(errno: error)
            }
            if count == 0 { break }

            var record = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                if let entry = Self.parse(record: record) { entries.append(entry) }
                record += length
            }
        }
        return entries
    }

    /// Layout of a record (all fields packed, in this order):
    /// length, returned attribute set, [error], name reference, device, object type, access mask,
    /// [directory mount status], [file total size, file allocated size]
    private static func parse(record: UnsafeRawPointer) -> RawEntry? {
        var field = record + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        func has(_ common: Int32) -> Bool { returned.commonattr & attrgroup_t(common) != 0 }

        if has(Int32(bitPattern: UInt32(ATTR_CMN_ERROR))) {
            let error = field.loadUnaligned(as: UInt32.self)
            field += 4
            if error != 0 { return nil }
        }

        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let reference = field.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        field += MemoryLayout<attrreference_t>.size

        var device: UInt64 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            device = UInt64(field.loadUnaligned(as: UInt32.self))
            field += 4
        }
        var objectType: UInt32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            objectType = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        var mode: UInt32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_ACCESSMASK) != 0 {
            mode = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        var mountStatus: UInt32 = 0
        if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            mountStatus = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        var logical: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 {
            logical = field.loadUnaligned(as: Int64.self)
            field += 8
        }
        var physical: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            physical = field.loadUnaligned(as: Int64.self)
            field += 8
        }

        // fsobj_type_t values (VREG = 1, VDIR = 2, VLNK = 5)
        let kind: RawEntry.Kind
        switch objectType {
        case 1: kind = .file
        case 2: kind = .directory
        case 5: kind = .symlink
        default: kind = .other
        }
        let hasSize = kind != .directory
        return RawEntry(
            name: name,
            kind: kind,
            logicalSize: hasSize ? UInt64(max(0, logical)) : 0,
            physicalSize: hasSize ? UInt64(max(0, physical)) : 0,
            device: device,
            isMountPoint: kind == .directory && mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0,
            isExecutable: mode & 0o111 != 0)
    }
}

#endif
