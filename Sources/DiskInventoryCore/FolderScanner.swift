import Foundation

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
/// * Folders are read in parallel on all processor cores.
/// * Symbolic links are never followed (they count with their own, tiny, size).
/// * Other volumes mounted below the folder are not entered.
/// * Folders which cannot be read (missing permissions) stay in the tree as empty folders.
///
/// `onProgress` and `isCancelled` are called from the scanning threads, but never concurrently.
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

    /// How directories are read (replaceable for testing). The fallback is used if the primary reader
    /// reports that it can't handle a directory (e.g. on a network volume).
    var primaryReader: DirectoryReader = FolderScanner.defaultReader
    var fallbackReader: DirectoryReader = POSIXDirectoryReader()

    #if canImport(Darwin)
    static var defaultReader: DirectoryReader { BulkDirectoryReader() }
    #else
    static var defaultReader: DirectoryReader { POSIXDirectoryReader() }
    #endif

    private let kinds = KindResolver()

    public init(sizeMode: SizeMode = .logical,
                onProgress: ((Progress) -> Void)? = nil,
                isCancelled: @escaping () -> Bool = { false }) {
        self.sizeMode = sizeMode
        self.onProgress = onProgress
        self.isCancelled = isCancelled
    }

    // MARK: - Scanning

    /// State shared by the worker threads of one scan.
    private final class Run {
        let lock = NSLock()
        var itemCount = 0
        var unreadable = 0
        var cancelled = false
        var rootError: Error?
        let group = DispatchGroup()

        // statistics for DIX_SCAN_STATS=1 (nanoseconds summed over all threads)
        var readNanos: UInt64 = 0
        var packageNanos: UInt64 = 0
        var packageCalls = 0
        var directories = 0
    }

    @inline(__always)
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Scans `url` (a folder, or a single file) and returns the root of the resulting tree.
    public func scan(url: URL) throws -> FSItem {
        let rootURL = url.standardizedFileURL
        let path = rootURL.path

        var st = stat()
        guard stat(path, &st) == 0 else { throw ScanError.doesNotExist(url) }
        let isDirectory = UInt32(st.st_mode) & 0o170000 == 0o040000

        var localKinds: [String: String] = [:]
        let root: FSItem
        if isDirectory {
            let package = KindResolver.packageInfo(atPath: path)
            root = FSItem(rootURL: rootURL, isDirectory: true, isPackage: package.isPackage,
                          kindName: package.kind ?? kinds.folderKind)
        } else {
            let kind = kinds.kind(forFileNamed: rootURL.lastPathComponent,
                                  isExecutable: st.st_mode & 0o111 != 0, local: &localKinds)
            root = FSItem(rootURL: rootURL, isDirectory: false, kindName: kind)
            root.setSizes(logical: UInt64(max(0, Int(st.st_size))), physical: UInt64(max(0, Int(st.st_blocks))) * 512)
            root.applySizeMode(sizeMode)
            return root
        }

        root.prepareForBuild(sizeMode: sizeMode)

        let run = Run()
        let scanStart = Self.now()
        enqueue(node: root, path: path, device: UInt64(st.st_dev), isRoot: true, run: run)
        run.group.wait()
        let scanEnd = Self.now()

        if run.cancelled { throw ScanError.cancelled }
        if let error = run.rootError { throw ScanError.unreadable(url, underlying: error) }

        let finalizeStart = Self.now()
        finalize(root)
        if ProcessInfo.processInfo.environment["DIX_SCAN_STATS"] != nil {
            func ms(_ n: UInt64) -> String { String(format: "%.0f ms", Double(n) / 1e6) }
            let text = "scan statistics: walk \(ms(scanEnd - scanStart)) wall, finalize \(ms(Self.now() - finalizeStart)); "
                + "summed over threads: reading directories \(ms(run.readNanos)) (\(run.directories) directories), "
                + "package lookups \(ms(run.packageNanos)) (\(run.packageCalls) calls)\n"
            FileHandle.standardError.write(Data(text.utf8))
        }
        return root
    }

    private func enqueue(node: FSItem, path: String, device: UInt64, isRoot: Bool, run: Run) {
        run.group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { run.group.leave() }
            self.process(node: node, path: path, device: device, isRoot: isRoot, run: run)
        }
    }

    /// Reads one folder, adds its entries to `node` and schedules its subfolders.
    /// Every folder is processed by exactly one thread, so a node is never modified concurrently.
    private func process(node: FSItem, path: String, device: UInt64, isRoot: Bool, run: Run) {
        run.lock.lock()
        if run.cancelled || isCancelled() {
            run.cancelled = true
            run.lock.unlock()
            return
        }
        onProgress?(Progress(currentFolder: path, itemCount: run.itemCount, unreadableFolders: run.unreadable))
        run.lock.unlock()

        let entries: [RawEntry]
        let readStart = Self.now()
        do {
            entries = try readEntries(atPath: path, device: device)
        } catch {
            run.lock.lock()
            if isRoot { run.rootError = error } else { run.unreadable += 1 }
            run.lock.unlock()
            return
        }

        let readNanos = Self.now() - readStart
        var packageNanos: UInt64 = 0
        var packageCalls = 0

        var localKinds: [String: String] = [:]
        var subfolders: [(FSItem, String, UInt64)] = []
        var parentIsVolumeRoot: Bool?   // determined when needed
        let basePath = path.hasSuffix("/") ? path : path + "/"

        for entry in entries {
            let kind: String
            var isPackage = false
            switch entry.kind {
            case .directory:
                let ext = KindResolver.fileExtension(of: entry.name)
                if !ext.isEmpty {
                    // only folders with an extension can be packages
                    let t = Self.now()
                    let info = KindResolver.packageInfo(atPath: basePath + entry.name)
                    packageNanos += Self.now() - t
                    packageCalls += 1
                    isPackage = info.isPackage
                    kind = info.kind ?? kinds.folderKind
                } else {
                    kind = kinds.folderKind
                }
            case .symlink:
                kind = kinds.symlinkKind
            case .file, .other:
                kind = kinds.kind(forFileNamed: entry.name, isExecutable: entry.isExecutable, local: &localKinds)
            }

            let child = FSItem(
                name: entry.name,
                isDirectory: entry.kind == .directory,
                isPackage: isPackage,
                isSymbolicLink: entry.kind == .symlink,
                kindName: kind,
                logicalSize: entry.logicalSize,
                physicalSize: entry.physicalSize)
            node.addChild(child)

            guard entry.kind == .directory, !entry.isMountPoint else { continue }

            // don't look into special directories of a volume root
            if FolderScanner.pseudoDirectoryNames.contains(entry.name) {
                if parentIsVolumeRoot == nil { parentIsVolumeRoot = isVolumeRoot(URL(fileURLWithPath: path)) }
                if parentIsVolumeRoot == true { continue }
            }
            subfolders.append((child, basePath + entry.name, entry.device))
        }

        run.lock.lock()
        run.itemCount += entries.count
        run.readNanos += readNanos
        run.packageNanos += packageNanos
        run.packageCalls += packageCalls
        run.directories += 1
        run.lock.unlock()

        for (child, childPath, childDevice) in subfolders {
            enqueue(node: child, path: childPath, device: childDevice, isRoot: false, run: run)
        }
    }

    private func readEntries(atPath path: String, device: UInt64) throws -> [RawEntry] {
        do {
            return try primaryReader.readEntries(atPath: path, parentDevice: device)
        } catch DirectoryReadError.unsupported {
            return try fallbackReader.readEntries(atPath: path, parentDevice: device)
        }
    }

    /// Adds up sizes and sorts all folders, bottom-up.
    private func finalize(_ item: FSItem) {
        guard item.isDirectory else { return }
        for child in item.children { finalize(child) }
        item.finalizeChildren()
    }
}
