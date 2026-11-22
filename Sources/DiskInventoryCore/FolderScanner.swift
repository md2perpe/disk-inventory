import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public enum ScanError: Error, LocalizedError {
    case doesNotExist(URL)
    case cancelled
    case unreadable(URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .doesNotExist(let url):
            return "“\(url.path)” does not exist."
        case .cancelled:
            return "The scan was cancelled."
        case .unreadable(let url, let underlying):
            return "The contents of “\(url.path)” could not be read: \(underlying.localizedDescription)"
        }
    }
}

/// Builds an `FSItem` tree for a folder.
///
/// * Symbolic links are never followed (they count with their own, tiny, size).
/// * Other volumes mounted below the folder are not entered.
/// * Folders which cannot be read (missing permissions) stay in the tree as empty folders.
///
/// A scanner is meant to be used from one thread at a time; `onProgress` and `isCancelled` are called
/// on the scanning thread.
public final class FolderScanner {
    public struct Progress: Sendable {
        /// path of the folder which is currently being read
        public var currentFolder: String
        /// number of files and folders found so far
        public var itemCount: Int
        /// number of folders which could not be read
        public var unreadableFolders: Int
    }

    public var sizeMode: SizeMode
    public var onProgress: ((Progress) -> Void)?
    public var isCancelled: () -> Bool

    /// Special directories in the root of a volume. They are not real folders but ways to address files by other
    /// means (`/.nofollow`, `/.resolve`, `/.vol`). Depending on the macOS version listing them yields nothing
    /// or - on macOS 26 - a second copy of the whole volume, so their contents are never scanned.
    static let pseudoDirectoryNames: Set<String> = [".nofollow", ".resolve", ".vol"]

    /// Tells whether a folder is the root of a volume (replaceable for testing).
    var isVolumeRoot: (URL) -> Bool = { url in
        if url.path == "/" { return true }
        #if canImport(Darwin)
        return (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
        #else
        return false
        #endif
    }

    private var itemCount = 0
    private var unreadable = 0
    private var kindCache: [String: String] = [:]
    private let fileManager = FileManager.default

    public init(sizeMode: SizeMode = .logical,
                onProgress: ((Progress) -> Void)? = nil,
                isCancelled: @escaping () -> Bool = { false }) {
        self.sizeMode = sizeMode
        self.onProgress = onProgress
        self.isCancelled = isCancelled
    }

    /// Scans `url` (a folder, or a single file) and returns the root of the resulting tree.
    public func scan(url: URL) throws -> FSItem {
        itemCount = 0
        unreadable = 0

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ScanError.doesNotExist(url)
        }

        let info = entryInfo(for: url, parentDevice: nil)
        let root = FSItem(
            rootURL: url.standardizedFileURL,
            isDirectory: isDir.boolValue,
            isPackage: info.isPackage,
            kindName: isDir.boolValue ? (info.kind.isEmpty ? "Folder" : info.kind) : info.kind)

        if isDir.boolValue {
            try scanChildren(of: root, at: url, device: info.device)
        } else {
            // a single file
            root.setSizes(logical: info.logicalSize, physical: info.physicalSize)
        }

        root.applySizeMode(sizeMode)
        return root
    }

    // MARK: - Walking the tree

    private func scanChildren(of item: FSItem, at url: URL, device: UInt64) throws {
        if isCancelled() { throw ScanError.cancelled }

        onProgress?(Progress(currentFolder: url.path, itemCount: itemCount, unreadableFolders: unreadable))

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: FolderScanner.prefetchedKeys, options: [])
        } catch {
            if item.isRoot { throw ScanError.unreadable(url, underlying: error) }
            unreadable += 1
            return
        }

        var parentIsVolumeRoot: Bool?   // determined when needed

        for childURL in urls {
            let info = entryInfo(for: childURL, parentDevice: device)

            var isPseudoDirectory = false
            if info.isDirectory && FolderScanner.pseudoDirectoryNames.contains(childURL.lastPathComponent) {
                if parentIsVolumeRoot == nil { parentIsVolumeRoot = isVolumeRoot(url) }
                isPseudoDirectory = parentIsVolumeRoot == true
            }

            let child = FSItem(
                name: childURL.lastPathComponent,
                isDirectory: info.isDirectory,
                isPackage: info.isPackage,
                isSymbolicLink: info.isSymbolicLink,
                kindName: info.kind,
                logicalSize: info.logicalSize,
                physicalSize: info.physicalSize)
            item.addChild(child)
            itemCount += 1

            // don't descend into other volumes mounted inside the folder
            if info.isDirectory && !info.isVolumeRoot && !isPseudoDirectory {
                try scanChildren(of: child, at: childURL, device: info.device)
            }
        }
        item.finalizeChildren()
    }

    // MARK: - Reading file attributes

    private struct EntryInfo {
        var isDirectory = false
        var isSymbolicLink = false
        var isPackage = false
        /// a directory that is the root of another volume (a mount point)
        var isVolumeRoot = false
        var logicalSize: UInt64 = 0
        var physicalSize: UInt64 = 0
        var kind = ""
        /// id of the volume the entry is on (only determined on platforms without resource keys)
        var device: UInt64 = 0
    }

    #if canImport(Darwin)

    // On macOS Foundation prefetches these properties for a whole directory in one bulk call,
    // so asking for them per file is cheap.
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isVolumeKey,
        .fileSizeKey, .totalFileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
        .contentTypeKey,
    ]
    private static let prefetchedKeys: [URLResourceKey]? = resourceKeys
    private static let resourceKeySet = Set(resourceKeys)

    private func entryInfo(for url: URL, parentDevice: UInt64?) -> EntryInfo {
        var info = EntryInfo()
        guard let values = try? url.resourceValues(forKeys: FolderScanner.resourceKeySet) else {
            info.kind = kind(forIdentifier: nil, type: nil, isDirectory: false, url: url)
            return info
        }
        info.isSymbolicLink = values.isSymbolicLink ?? false
        info.isDirectory = (values.isDirectory ?? false) && !info.isSymbolicLink
        info.isPackage = values.isPackage ?? false
        info.isVolumeRoot = parentDevice != nil && (values.isVolume ?? false)
        if !info.isDirectory {
            let logical = values.totalFileSize ?? values.fileSize ?? 0
            let physical = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? logical
            info.logicalSize = UInt64(max(0, logical))
            info.physicalSize = UInt64(max(0, physical))
        }
        let type = values.contentType
        info.kind = kind(forIdentifier: type?.identifier, type: type, isDirectory: info.isDirectory, url: url)
        return info
    }

    private func kind(forIdentifier id: String?, type: UTType?, isDirectory: Bool, url: URL) -> String {
        if let id, let cached = kindCache[id] { return cached }
        let name = type?.localizedDescription ?? (isDirectory ? "Folder" : "Document")
        if let id { kindCache[id] = name }
        return name
    }

    #else

    // Foundation on other platforms (Linux) implements most resource keys by doing separate, slow system calls,
    // so plain lstat() is used instead. This path is used by the command line tool and the tests.
    private static let prefetchedKeys: [URLResourceKey]? = nil

    private func entryInfo(for url: URL, parentDevice: UInt64?) -> EntryInfo {
        var info = EntryInfo()
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            info.kind = kind(forExtension: url.pathExtension, isDirectory: false)
            return info
        }
        let type = UInt32(st.st_mode) & 0o170000
        info.isSymbolicLink = type == 0o120000
        info.isDirectory = type == 0o040000
        info.device = UInt64(st.st_dev)
        info.isVolumeRoot = info.isDirectory && parentDevice != nil && info.device != parentDevice
        if !info.isDirectory {
            info.logicalSize = UInt64(max(0, Int(st.st_size)))
            info.physicalSize = UInt64(max(0, Int(st.st_blocks))) * 512
        }
        info.kind = kind(forExtension: url.pathExtension, isDirectory: info.isDirectory)
        return info
    }

    private func kind(forExtension ext: String, isDirectory: Bool) -> String {
        if isDirectory { return "Folder" }
        let ext = ext.lowercased()
        if let cached = kindCache[ext] { return cached }
        let name = ext.isEmpty ? "Document" : "\(ext.uppercased()) document"
        kindCache[ext] = name
        return name
    }

    #endif
}
