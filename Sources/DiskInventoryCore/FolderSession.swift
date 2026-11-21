import Foundation
import Observation
import TreeMapKit

/// Data source that lays out an `FSItem` tree for `TreeMapLayout`.
///
/// The zoomed item is the root of the treemap; the free/other space pseudo items are appended to its children.
public struct FSTreeMapSource: TreeMapDataSource {
    public let top: FSItem
    public let extras: [FSItem]
    public let packagesAreFolders: Bool

    public init(top: FSItem, extras: [FSItem], packagesAreFolders: Bool) {
        self.top = top
        self.extras = extras
        self.packagesAreFolders = packagesAreFolders
    }

    public func children(of item: FSItem) -> [FSItem]? {
        if item === top { return extras.isEmpty ? item.children : item.children + extras }
        guard item.isFolder, packagesAreFolders || !item.isPackage else { return nil }
        return item.children
    }

    public func weight(of item: FSItem) -> UInt64 {
        item === top ? extras.reduce(item.size) { $0 + $1.size } : item.size
    }
}

/// Everything that belongs to one open folder window: the scanned tree, zoom, selection, view options
/// and kind statistics. (This is the replacement for the original `FileSystemDoc`.)
///
/// All state is observable, so SwiftUI views can bind to it directly. Mutations happen on the main actor,
/// only the file system scan itself runs on a background thread.
@MainActor
@Observable
public final class FolderSession {

    public struct Options: Sendable {
        public var showPackageContents = false
        public var showFreeSpace = false
        public var showOtherSpace = false
        public var physicalSizes = false
        public var sharesColors = false
        public init() {}
    }

    public let initialURL: URL

    // MARK: Observable state

    public private(set) var rootItem: FSItem?
    public private(set) var zoomStack: [FSItem] = []
    public private(set) var selectedItem: FSItem?
    public private(set) var kindStatistics: [FileKindStatistic] = []
    public private(set) var freeSpaceItem: FSItem?
    public private(set) var otherSpaceItem: FSItem?

    /// non-nil while a (re)scan is running
    public private(set) var scanProgress: FolderScanner.Progress?
    /// set if the initial scan failed or was cancelled
    public private(set) var failure: String?
    /// incremented whenever the tree, the zoom or a view option changes (views use it to rebuild)
    public private(set) var revision = 0

    public private(set) var showPackageContents: Bool
    public private(set) var showFreeSpace: Bool
    public private(set) var showOtherSpace: Bool
    public private(set) var sizeMode: SizeMode
    public private(set) var sharesColors: Bool

    /// the item under the mouse pointer in the treemap
    public var hoveredItem: FSItem?
    /// a message to show to the user (non fatal errors)
    public var errorMessage: String?
    /// an item waiting for the user's confirmation to be deleted immediately (items on network volumes can't be trashed)
    public private(set) var pendingDeletion: FSItem?

    // MARK: Internals

    @ObservationIgnored private let ownColors = FileTypeColors()
    @ObservationIgnored private var cancelFlag: CancelFlag?
    @ObservationIgnored private var didStart = false

    /// Moves a file to the trash (or deletes it). Replaceable for testing.
    @ObservationIgnored public var trashHandler: (URL, _ permanently: Bool) throws -> Void = { url, permanently in
        #if os(macOS)
        if permanently {
            try FileManager.default.removeItem(at: url)
        } else {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        #else
        try FileManager.default.removeItem(at: url)
        #endif
    }

    public init(url: URL, options: Options = Options()) {
        self.initialURL = url
        self.showPackageContents = options.showPackageContents
        self.showFreeSpace = options.showFreeSpace
        self.showOtherSpace = options.showOtherSpace
        self.sizeMode = options.physicalSizes ? .physical : .logical
        self.sharesColors = options.sharesColors
    }

    // MARK: - Derived state

    public var zoomedItem: FSItem? { zoomStack.last ?? rootItem }

    public var isScanning: Bool { scanProgress != nil }

    public var colors: FileTypeColors { sharesColors ? FileTypeColors.shared : ownColors }

    /// Window title: name and total size of the zoomed item.
    public var title: String {
        guard let zoomed = zoomedItem else { return initialURL.lastPathComponent }
        return "\(zoomed.displayName) (\(SizeFormatting.string(forBytes: zoomed.size)))"
    }

    /// Folders are nodes in the treemap/outline; packages only if "show package contents" is on.
    /// The zoomed item is always a node (you can always zoom into a package).
    public func isNode(_ item: FSItem) -> Bool {
        if item === zoomedItem { return true }
        return item.isFolder && (showPackageContents || !item.isPackage)
    }

    /// There is no "other space" if a whole volume is shown.
    public var canShowOtherSpace: Bool {
        guard let zoomed = zoomedItem else { return false }
        return !Self.isVolumeRoot(zoomed.url)
    }

    public var canZoomIn: Bool {
        guard let sel = selectedItem else { return false }
        return sel.isFolder && sel !== zoomedItem
    }

    public var canZoomOut: Bool { !zoomStack.isEmpty }

    public var canSelectParent: Bool {
        guard let sel = selectedItem else { return false }
        return sel !== zoomedItem && sel.parent !== zoomedItem
    }

    public func canTrash(_ item: FSItem?) -> Bool {
        guard let item, !item.isSpecialItem, item !== zoomedItem, item.parent != nil else { return false }
        return !Self.isInTrash(item.url)
    }

    public func treeMapSource() -> FSTreeMapSource? {
        guard let top = zoomedItem else { return nil }
        var extras: [FSItem] = []
        if showOtherSpace, canShowOtherSpace, let other = otherSpaceItem { extras.append(other) }
        if showFreeSpace, let free = freeSpaceItem { extras.append(free) }
        return FSTreeMapSource(top: top, extras: extras, packagesAreFolders: showPackageContents)
    }

    public func color(for item: FSItem) -> RGB {
        switch item.type {
        case .freeSpace: return FileTypeColors.freeSpaceColor
        case .otherSpace: return FileTypeColors.otherSpaceColor
        case .fileOrFolder: return colors.color(forKind: item.kindName)
        }
    }

    /// All files of a kind in the zoomed folder (or of all kinds if `kind` is nil).
    public func items(ofKind kind: String?) -> [FSItem] {
        if let kind { return kindStatistics.first { $0.kindName == kind }?.items ?? [] }
        return kindStatistics.flatMap(\.items)
    }

    // MARK: - Scanning

    /// Performs the initial scan. Call once; does nothing on later calls.
    public func scan() async {
        guard !didStart else { return }
        didStart = true
        failure = nil
        do {
            let root = try await runScan(url: initialURL)
            rootItem = root
            zoomStack = []
            selectedItem = nil
            scanProgress = nil
            treeChanged()
        } catch {
            scanProgress = nil
            if case ScanError.cancelled = error {
                failure = "The scan was cancelled."
            } else {
                failure = error.localizedDescription
            }
        }
    }

    /// Installs an already built tree instead of scanning (used by tests).
    func adopt(root: FSItem) {
        didStart = true
        rootItem = root
        zoomStack = []
        selectedItem = nil
        root.applySizeMode(sizeMode)
        treeChanged()
    }

    public func cancelScan() {
        cancelFlag?.set()
    }

    /// Rescans `item` (the zoomed item if nil) and replaces it in the tree.
    /// If the item doesn't exist any more, its closest existing ancestor is rescanned instead.
    public func refresh(_ requested: FSItem? = nil) async {
        guard scanProgress == nil, let root = rootItem else { return }

        var target: FSItem? = requested ?? zoomedItem
        while let t = target, !FileManager.default.fileExists(atPath: t.path) {
            target = t.parent
        }
        guard let target else {
            errorMessage = "“\(root.displayName)” does not exist any more. The folder stays visible, but its files cannot be accessed."
            return
        }

        let selectedPath = selectedItem?.path
        let zoomPaths = zoomStack.map(\.path)

        let fresh: FSItem
        do {
            fresh = try await runScan(url: target.url)
        } catch {
            scanProgress = nil
            if case ScanError.cancelled = error {} else { errorMessage = error.localizedDescription }
            return
        }
        scanProgress = nil

        // the tree may have been changed (e.g. an item was trashed) while we were scanning
        guard target.root === rootItem else { return }

        if target === rootItem {
            rootItem = fresh
        } else {
            target.parent?.replaceChild(target, with: fresh)
        }

        // re-resolve zoom stack and selection in the new tree (by path; folders that vanished zoom us out)
        guard let newRoot = rootItem else { return }
        zoomStack = []
        for path in zoomPaths {
            guard let item = newRoot.findItem(atPath: path, allowAncestors: false), item.isFolder else { break }
            zoomStack.append(item)
        }
        if let selectedPath, let item = newRoot.findItem(atPath: selectedPath, allowAncestors: true),
           let zoomed = zoomedItem, item !== zoomed, item.isDescendant(of: zoomed) {
            selectedItem = item
        } else {
            selectedItem = nil
        }
        treeChanged()
    }

    private func runScan(url: URL) async throws -> FSItem {
        let flag = CancelFlag()
        cancelFlag = flag
        scanProgress = FolderScanner.Progress(currentFolder: url.path, itemCount: 0, unreadableFolders: 0)
        let mode = sizeMode

        let result: Result<ItemBox, Error> = await Task.detached(priority: .userInitiated) { [weak self] in
            var lastReport = Date.distantPast
            let scanner = FolderScanner(
                sizeMode: mode,
                onProgress: { progress in
                    // don't flood the main thread with an update for every folder
                    let now = Date()
                    guard now.timeIntervalSince(lastReport) > 0.1 else { return }
                    lastReport = now
                    Task { @MainActor [weak self] in
                        if self?.scanProgress != nil { self?.scanProgress = progress }
                    }
                },
                isCancelled: { flag.isSet })
            do {
                return .success(ItemBox(item: try scanner.scan(url: url)))
            } catch {
                return .failure(error)
            }
        }.value

        cancelFlag = nil
        return try result.get().item
    }

    // MARK: - Zoom

    public func zoomIn() {
        guard canZoomIn, let item = selectedItem else { return }
        zoomStack.append(item)
        selectedItem = nil
        treeChanged()
    }

    /// Zooms out one level and selects the folder we just left.
    public func zoomOut() {
        guard let left = zoomStack.popLast() else { return }
        selectedItem = left
        treeChanged()
    }

    /// Zooms out until `item` (an item of the zoom stack, or the root) is the zoomed item.
    public func zoomOut(to item: FSItem) {
        guard let leftTop = zoomedItem, item !== leftTop else { return }
        if item === rootItem {
            zoomStack.removeAll()
        } else if let index = zoomStack.firstIndex(where: { $0 === item }) {
            zoomStack.removeSubrange((index + 1)...)
        } else {
            return
        }
        selectedItem = leftTop
        treeChanged()
    }

    // MARK: - Selection

    public func select(_ item: FSItem?) {
        let item = (item?.isSpecialItem ?? false) ? nil : item
        guard item !== selectedItem else { return }
        selectedItem = item
    }

    public func selectParent() {
        guard canSelectParent, let parent = selectedItem?.parent else { return }
        selectedItem = parent
    }

    // MARK: - Options

    public func setShowPackageContents(_ show: Bool) {
        guard show != showPackageContents else { return }
        showPackageContents = show

        // if the selection is inside a package which is now regarded as a file, select that package instead
        if !show, let selected = selectedItem {
            var package: FSItem?
            var parent = selected.parent
            while let p = parent, p !== zoomedItem {
                if p.isPackage { package = p }
                parent = p.parent
            }
            if let package { selectedItem = package }
        }
        treeChanged()
    }

    public func setShowFreeSpace(_ show: Bool) {
        guard show != showFreeSpace else { return }
        showFreeSpace = show
        revision += 1
    }

    public func setShowOtherSpace(_ show: Bool) {
        guard show != showOtherSpace else { return }
        showOtherSpace = show
        revision += 1
    }

    public func setPhysicalSizes(_ physical: Bool) {
        let mode: SizeMode = physical ? .physical : .logical
        guard mode != sizeMode else { return }
        sizeMode = mode
        rootItem?.applySizeMode(mode)
        treeChanged()
    }

    public func setSharesColors(_ shares: Bool) {
        guard shares != sharesColors else { return }
        FileTypeColors.shared.reset()
        ownColors.reset()
        sharesColors = shares
        colors.reserveColors(for: kindStatistics)
        revision += 1
    }

    // MARK: - Trash

    /// Moves `item` to the trash. Items on network volumes can't be trashed, so the user is asked first
    /// whether they should be deleted immediately (see `pendingDeletion`).
    public func requestTrash(_ item: FSItem) {
        guard canTrash(item) else { return }
        if Self.isOnLocalVolume(item.url) {
            moveToTrash(item, permanently: false)
        } else {
            pendingDeletion = item
        }
    }

    public func confirmPendingDeletion() {
        guard let item = pendingDeletion else { return }
        pendingDeletion = nil
        moveToTrash(item, permanently: true)
    }

    public func cancelPendingDeletion() {
        pendingDeletion = nil
    }

    @discardableResult
    public func moveToTrash(_ item: FSItem, permanently: Bool) -> Bool {
        guard canTrash(item), let parent = item.parent else { return false }
        do {
            try trashHandler(item.url, permanently)
        } catch {
            errorMessage = "“\(item.displayName)” cannot be moved to the trash. \(error.localizedDescription)"
            return false
        }

        if let selected = selectedItem, selected === item || selected.isDescendant(of: item) {
            selectedItem = parent === zoomedItem ? nil : parent
        }
        parent.removeChild(item)
        treeChanged()
        return true
    }

    // MARK: - Private

    private func treeChanged() {
        updateSpaceItems()
        rebuildStatistics()
        revision += 1
    }

    private func rebuildStatistics() {
        guard let zoomed = zoomedItem else {
            kindStatistics = []
            return
        }
        kindStatistics = FileKindStatistics.collect(from: zoomed, isNode: { isNode($0) })
        colors.reserveColors(for: kindStatistics)
    }

    /// "Free space" and "other space" (everything on the volume that is not part of the scanned folder).
    private func updateSpaceItems() {
        guard let root = rootItem else {
            freeSpaceItem = nil
            otherSpaceItem = nil
            return
        }
        var total: UInt64 = 0
        var free: UInt64 = 0
        if let values = try? root.url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
            free = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
        }
        let used = root.size
        let other = total > used + free ? total - used - free : 0
        freeSpaceItem = FSItem(specialType: .freeSpace, size: free, parent: root)
        otherSpaceItem = FSItem(specialType: .otherSpace, size: other, parent: root)
    }

    // MARK: - Volume helpers

    static func isVolumeRoot(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
    }

    static func isOnLocalVolume(_ url: URL) -> Bool {
        #if os(macOS)
        return (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
        #else
        return true
        #endif
    }

    static func isInTrash(_ url: URL) -> Bool {
        #if os(macOS)
        guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false) else {
            return false
        }
        let a = url.standardizedFileURL.pathComponents, b = trash.standardizedFileURL.pathComponents
        return a.count >= b.count && Array(a.prefix(b.count)) == b
        #else
        return false
        #endif
    }
}

// MARK: - Helpers for the scan task

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// The scanned tree is created on a background thread and handed over to the main actor exactly once.
private struct ItemBox: @unchecked Sendable {
    let item: FSItem
}
