import Foundation

public enum FSItemType: UInt8, Sendable {
    /// a regular file or folder
    case fileOrFolder
    /// the space on the volume occupied by files which are not part of the scanned folder
    case otherSpace
    /// free space on the volume
    case freeSpace
}

/// Which size is used for sorting and for the area in the treemap.
public enum SizeMode: UInt8, Sendable {
    /// number of bytes in the file (what the Finder shows)
    case logical
    /// number of bytes allocated on disk (differs because of block sizes, compression, sparse files)
    case physical
}

/// A file, folder or one of the two pseudo items (free / other space) of the file tree.
///
/// The tree is built once by `FolderScanner` and afterwards only changed on the main thread
/// (removing an item, refreshing a subtree, switching the size mode).
/// Children are always kept sorted by descending size.
public final class FSItem: Identifiable, Hashable {
    public let type: FSItemType
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool

    /// the "kind" as shown in the Finder, e.g. "PDF document"; empty for folders' children aggregate
    public private(set) var kindName: String

    public private(set) var logicalSize: UInt64
    public private(set) var physicalSize: UInt64
    public private(set) var sizeMode: SizeMode = .logical

    public private(set) weak var parent: FSItem?
    public private(set) var children: [FSItem] = []

    /// Only set for the root item of a tree (all other items derive their URL from the parent chain).
    private var rootURL: URL?

    // MARK: Creation

    /// Creates the root of a tree.
    public init(rootURL: URL, isDirectory: Bool = true, isPackage: Bool = false, kindName: String = "Folder") {
        self.type = .fileOrFolder
        self.name = rootURL.lastPathComponent.isEmpty ? "/" : rootURL.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = false
        self.kindName = kindName
        self.logicalSize = 0
        self.physicalSize = 0
        self.rootURL = rootURL
    }

    public init(
        name: String,
        isDirectory: Bool,
        isPackage: Bool = false,
        isSymbolicLink: Bool = false,
        kindName: String,
        logicalSize: UInt64 = 0,
        physicalSize: UInt64 = 0
    ) {
        self.type = .fileOrFolder
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.kindName = kindName
        self.logicalSize = logicalSize
        self.physicalSize = physicalSize
    }

    /// Creates a free space / other space pseudo item whose size is given explicitly.
    public init(specialType: FSItemType, size: UInt64, parent: FSItem?) {
        precondition(specialType != .fileOrFolder)
        self.type = specialType
        self.name = specialType == .freeSpace ? "free space" : "other space"
        self.isDirectory = false
        self.isPackage = false
        self.isSymbolicLink = false
        self.kindName = ""
        self.logicalSize = size
        self.physicalSize = size
        self.parent = parent
    }

    public static func == (lhs: FSItem, rhs: FSItem) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    // MARK: Classification

    public var isSpecialItem: Bool { type != .fileOrFolder }

    /// A real directory (a symbolic link to a directory is *not* a folder, it's never followed).
    public var isFolder: Bool { type == .fileOrFolder && isDirectory && !isSymbolicLink }

    public var isRoot: Bool { parent == nil }

    public var root: FSItem {
        var item = self
        while let p = item.parent { item = p }
        return item
    }

    public func isDescendant(of ancestor: FSItem) -> Bool {
        var item = parent
        while let p = item {
            if p === ancestor { return true }
            item = p.parent
        }
        return false
    }

    // MARK: Names and paths

    public var url: URL {
        if let rootURL { return rootURL }
        guard let parent, type == .fileOrFolder else { return root.url }
        return parent.url.appendingPathComponent(name, isDirectory: isFolder)
    }

    public var path: String { url.path }

    /// Path of the folder containing the item.
    public var folderPath: String {
        guard let parent else { return url.deletingLastPathComponent().path }
        return parent.path
    }

    /// Name for display purposes (localised for pseudo items).
    public var displayName: String {
        switch type {
        case .fileOrFolder:
            if isRoot { return FileManager.default.displayName(atPath: path) }
            return name
        case .freeSpace:
            return NSLocalizedString("free space on drive", comment: "")
        case .otherSpace:
            return NSLocalizedString("space occupied by other files and folders", comment: "")
        }
    }

    /// Path of the item relative to the root's parent folder, e.g. "Documents/Taxes/2024.pdf" for root "Documents".
    public var pathRelativeToRoot: String {
        var parts: [String] = []
        var item: FSItem? = self
        while let i = item {
            parts.append(i.isRoot ? i.displayName : i.name)
            item = i.parent
        }
        return parts.reversed().joined(separator: "/")
    }

    // MARK: Sizes

    public var size: UInt64 { sizeMode == .logical ? logicalSize : physicalSize }

    public func size(for mode: SizeMode) -> UInt64 { mode == .logical ? logicalSize : physicalSize }

    // MARK: Children

    /// Children shown in an outline view (`nil` for leaves).
    public var outlineChildren: [FSItem]? { isFolder ? children : nil }

    /// Appends a child without updating any sizes. Used while building a tree; call `finalizeChildren()` afterwards.
    public func addChild(_ child: FSItem) {
        precondition(isDirectory && type == .fileOrFolder, "only directories can have children")
        child.parent = self
        child.sizeMode = sizeMode
        children.append(child)
    }

    /// Sets the sizes of a leaf directly (used by the scanner for a single file).
    func setSizes(logical: UInt64, physical: UInt64) {
        logicalSize = logical
        physicalSize = physical
    }

    /// Sums up the children's sizes and sorts them by descending size.
    public func finalizeChildren() {
        var logical: UInt64 = 0
        var physical: UInt64 = 0
        for c in children {
            logical &+= c.logicalSize
            physical &+= c.physicalSize
        }
        logicalSize = logical
        physicalSize = physical
        sortChildren()
    }

    /// Changes the size used for sorting and display for the whole subtree.
    public func applySizeMode(_ mode: SizeMode) {
        sizeMode = mode
        for c in children { c.applySizeMode(mode) }
        sortChildren()
    }

    func sortChildren() {
        children.sort(by: FSItem.sortsBefore)
    }

    /// Descending by size, ties broken by name.
    static func sortsBefore(_ a: FSItem, _ b: FSItem) -> Bool {
        let sa = a.size, sb = b.size
        if sa != sb { return sa > sb }
        return a.name.compare(b.name, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }

    // MARK: Mutation (keeps the sizes of all ancestors in sync)

    /// Removes `child`, subtracting its size from this item and all ancestors.
    @discardableResult
    public func removeChild(_ child: FSItem) -> Bool {
        guard let index = children.firstIndex(where: { $0 === child }) else { return false }
        children.remove(at: index)
        child.parent = nil
        propagateSizeChange(logical: child.logicalSize, physical: child.physicalSize, adding: false)
        return true
    }

    /// Inserts `child` at its sorted position, adding its size to this item and all ancestors.
    public func insertChild(_ child: FSItem) {
        child.parent = self
        child.applySizeMode(sizeMode)
        let index = children.firstIndex(where: { FSItem.sortsBefore(child, $0) }) ?? children.count
        children.insert(child, at: index)
        propagateSizeChange(logical: child.logicalSize, physical: child.physicalSize, adding: true)
    }

    public func replaceChild(_ old: FSItem, with new: FSItem) {
        guard old !== new else { return }
        removeChild(old)
        insertChild(new)
    }

    /// Adds/subtracts a size from this item and every ancestor, keeping each ancestor sorted within its parent.
    private func propagateSizeChange(logical: UInt64, physical: UInt64, adding: Bool) {
        var node: FSItem? = self
        while let n = node {
            if adding {
                n.logicalSize &+= logical
                n.physicalSize &+= physical
            } else {
                n.logicalSize &-= min(n.logicalSize, logical)
                n.physicalSize &-= min(n.physicalSize, physical)
            }
            n.parent?.sortChildren()
            node = n.parent
        }
    }

    // MARK: Lookup

    /// Items from the root down to `self`.
    public var pathFromRoot: [FSItem] { pathFromAncestor(nil) }

    /// Items from `ancestor` (included) down to `self`; if `ancestor` is nil or no ancestor, from the root.
    public func pathFromAncestor(_ ancestor: FSItem?) -> [FSItem] {
        var result: [FSItem] = []
        var item: FSItem? = self
        while let i = item {
            result.append(i)
            if i === ancestor { break }
            item = i.parent
        }
        return result.reversed()
    }

    /// Finds a descendant by absolute path. If `allowAncestors` is true and the exact item doesn't exist,
    /// the deepest existing ancestor is returned instead.
    public func findItem(atPath target: String, allowAncestors: Bool) -> FSItem? {
        let myPath = path
        if target == myPath { return self }
        let prefix = myPath.hasSuffix("/") ? myPath : myPath + "/"
        guard target.hasPrefix(prefix) else { return nil }
        let components = target.dropFirst(prefix.count).split(separator: "/").map(String.init)

        var current = self
        for name in components {
            guard let next = current.children.first(where: { $0.name == name }) else {
                return allowAncestors ? current : nil
            }
            current = next
        }
        return current
    }

    /// Number of files below this item (folders not counted), optionally also inside packages.
    public func deepFileCount(includingPackages: Bool) -> Int {
        var count = 0
        for c in children {
            if c.isFolder {
                if includingPackages || !c.isPackage { count += c.deepFileCount(includingPackages: includingPackages) }
            } else {
                count += 1
            }
        }
        return count
    }
}
