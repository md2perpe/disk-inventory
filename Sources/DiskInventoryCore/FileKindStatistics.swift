import Foundation

/// Summary of all files of one kind ("PDF document", "Application", ...) below a folder.
public final class FileKindStatistic: Identifiable {
    public let kindName: String
    public private(set) var items: [FSItem]
    public private(set) var size: UInt64

    public var id: String { kindName }
    public var fileCount: Int { items.count }

    init(kindName: String) {
        self.kindName = kindName
        self.items = []
        self.size = 0
    }

    func add(_ item: FSItem) {
        items.append(item)
        size &+= item.size
    }
}

public enum FileKindStatistics {
    /// Collects statistics for everything below `root`.
    ///
    /// - Parameter isNode: decides whether an item is traversed (folder) or counted (file). The caller decides
    ///   e.g. whether packages count as files or as folders. `root` itself is always traversed.
    /// - Returns: statistics ordered by descending size, ties broken by name.
    public static func collect(from root: FSItem, isNode: (FSItem) -> Bool) -> [FileKindStatistic] {
        var byKind: [String: FileKindStatistic] = [:]

        func visit(_ item: FSItem, isRoot: Bool) {
            if isRoot || isNode(item) {
                for child in item.children { visit(child, isRoot: false) }
            } else {
                let stat: FileKindStatistic
                if let existing = byKind[item.kindName] {
                    stat = existing
                } else {
                    stat = FileKindStatistic(kindName: item.kindName)
                    byKind[item.kindName] = stat
                }
                stat.add(item)
            }
        }
        visit(root, isRoot: true)

        return byKind.values.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.kindName.compare($1.kindName, options: .numeric) == .orderedAscending
        }
    }
}
