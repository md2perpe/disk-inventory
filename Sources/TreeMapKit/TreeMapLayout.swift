/// Supplies the tree that should be laid out.
///
/// Children are expected to be ordered by descending weight (the layout still works if they are not,
/// it just looks less pretty).
public protocol TreeMapDataSource {
    associatedtype Item: AnyObject

    /// The children of `item`, or `nil` if `item` is a leaf (a "file" in the treemap).
    /// An empty array means "node without children" (e.g. an empty folder).
    func children(of item: Item) -> [Item]?

    /// The area weight of `item` (e.g. its size in bytes). For nodes this should be the sum of the children.
    func weight(of item: Item) -> UInt64
}

/// The result of laying out one item of the tree.
public final class TreeMapCell<Item: AnyObject> {
    public let item: Item
    public let rect: PixelRect
    /// `true` if the data source reported the item as a leaf.
    public let isLeaf: Bool
    /// Laid out children. Children whose rectangle would be empty are not represented at all,
    /// and nodes that are too small to be subdivided have no cells for their children.
    public internal(set) var children: [TreeMapCell<Item>] = []

    init(item: Item, rect: PixelRect, isLeaf: Bool) {
        self.item = item
        self.rect = rect
        self.isLeaf = isLeaf
    }

    /// Finds the innermost cell containing the pixel. Returns a leaf, or a node that could not be subdivided.
    public func hitTest(x: Int, y: Int) -> TreeMapCell<Item>? {
        guard rect.contains(x: x, y: y) else { return nil }
        if isLeaf || children.isEmpty { return self }
        for child in children where child.rect.contains(x: x, y: y) {
            return child.hitTest(x: x, y: y)
        }
        return self
    }

    /// Finds the cell showing the last item of `path`, where `path` lists items from this cell's item downwards
    /// (`path[0]` must be this cell's item). Items are compared by identity.
    public func cell(forPath path: [Item]) -> TreeMapCell<Item>? {
        guard let first = path.first, first === item else { return nil }
        var current = self
        for next in path.dropFirst() {
            guard let child = current.children.first(where: { $0.item === next }) else { return nil }
            current = child
        }
        return current
    }
}

/// Squarified-style treemap layout ("row" algorithm of SequoiaView / KDirStat / WinDirStat).
///
/// Children are arranged in rows along the shorter side of the parent. A row is extended as long as the
/// aspect ratio of its cells does not get worse than `minProportion`. All coordinates are whole pixels;
/// the last cell of each row/column is stretched to the parent's border so there are never gaps.
public enum TreeMapLayout {
    /// - Parameters:
    ///   - root: the item to be laid out into `rect`
    ///   - minimumCellSize: nodes narrower or lower than this (in pixels) are not subdivided any further
    public static func layout<S: TreeMapDataSource>(
        root: S.Item,
        in rect: PixelRect,
        source: S,
        minimumCellSize: Int = 1
    ) -> TreeMapCell<S.Item> {
        build(item: root, rect: rect, source: source, minSize: max(1, minimumCellSize))
    }

    // MARK: - Recursion

    private static func build<S: TreeMapDataSource>(
        item: S.Item, rect: PixelRect, source: S, minSize: Int
    ) -> TreeMapCell<S.Item> {
        let kids = source.children(of: item)
        let cell = TreeMapCell(item: item, rect: rect, isLeaf: kids == nil)

        guard let kids, !kids.isEmpty, rect.width >= minSize, rect.height >= minSize else {
            return cell
        }

        let weights = kids.map { source.weight(of: $0) }
        let plan = arrange(weights: weights, nodeWeight: source.weight(of: item), width: rect.width, height: rect.height)

        let horizontal = plan.horizontalRows
        let parentWidth = horizontal ? rect.width : rect.height
        let parentHeight = horizontal ? rect.height : rect.width
        let parentBottom = horizontal ? rect.maxY : rect.maxX
        let parentRight = horizontal ? rect.maxX : rect.maxY
        let parentLeft = horizontal ? rect.x : rect.y

        var top = horizontal ? rect.y : rect.x
        var childIndex = 0
        cell.children.reserveCapacity(kids.count)

        for row in 0..<plan.rowHeights.count {
            var bottom = top + scaled(plan.rowHeights[row], parentHeight)
            // the last row must end exactly at the parent's border (gets rid of rounding errors)
            if bottom > parentBottom || row == plan.rowHeights.count - 1 { bottom = parentBottom }

            var left = parentLeft
            let columns = plan.childrenPerRow[row]

            for column in 0..<columns {
                var right = left + scaled(plan.childWidths[childIndex], parentWidth)
                if right > parentRight || column == columns - 1 { right = parentRight }

                let childRect = horizontal
                    ? PixelRect(x: left, y: top, width: right - left, height: bottom - top)
                    : PixelRect(x: top, y: left, width: bottom - top, height: right - left)

                if !childRect.isEmpty {
                    cell.children.append(build(item: kids[childIndex], rect: childRect, source: source, minSize: minSize))
                }

                left = right
                childIndex += 1
            }
            top = bottom
        }
        return cell
    }

    @inline(__always)
    private static func scaled(_ fraction: Double, _ length: Int) -> Int {
        let v = fraction * Double(length)
        return v.isFinite ? Int(v.rounded()) : 0
    }

    // MARK: - Row arrangement

    struct Plan {
        /// fraction of the parent's height taken by each row
        var rowHeights: [Double] = []
        /// number of children in each row
        var childrenPerRow: [Int] = []
        /// fraction of the parent's width taken by each child (indexed like the children)
        var childWidths: [Double] = []
        /// rows run left→right (true) or top→bottom (false)
        var horizontalRows = true
    }

    /// Ratio below which a row is not extended any further.
    static let minProportion = 0.4

    static func arrange(weights: [UInt64], nodeWeight: UInt64, width: Int, height: Int) -> Plan {
        var plan = Plan()
        let count = weights.count
        plan.childWidths.reserveCapacity(count)

        if nodeWeight == 0 {
            // nothing to base proportions on: one row, equally wide cells
            plan.rowHeights = [1]
            plan.childrenPerRow = [count]
            plan.childWidths = Array(repeating: 1.0 / Double(count), count: count)
            plan.horizontalRows = true
            return plan
        }

        plan.horizontalRows = width >= height

        // width of the parent measured in units of its height (or vice versa), see `calculateRow`
        var rowWidth = 1.0
        if plan.horizontalRows {
            if height > 0 { rowWidth = Double(width) / Double(height) }
        } else if width > 0 {
            rowWidth = Double(height) / Double(width)
        }

        var i = 0
        while i < count {
            let (rowHeight, used) = calculateRow(
                start: i, rowWidth: rowWidth, weights: weights, nodeWeight: Double(nodeWeight), widths: &plan.childWidths)
            plan.rowHeights.append(rowHeight)
            plan.childrenPerRow.append(used)
            i += used
        }
        return plan
    }

    /// Decides how many children go into the row starting at `start`, appends their widths and returns
    /// the row's height (as fraction of the parent's height) and the number of children used.
    private static func calculateRow(
        start: Int, rowWidth: Double, weights: [UInt64], nodeWeight mySize: Double, widths: inout [Double]
    ) -> (rowHeight: Double, used: Int) {
        let count = weights.count
        var sizeUsed = 0.0
        var rowHeight = 0.0
        var i = start

        while i < count {
            let childSize = Double(weights[i])
            if childSize == 0 { break }

            sizeUsed += childSize
            // clamp: tolerate children that add up to more than the parent
            let virtualRowHeight = min(sizeUsed / mySize, 1)

            // Rectangle(mySize)    = width * 1.0
            // Rectangle(childSize) = childWidth * virtualRowHeight
            let childWidth = childSize / mySize * rowWidth / virtualRowHeight

            // The first child of a row is always accepted (this also guarantees progress).
            if i > start && childWidth / virtualRowHeight < minProportion { break }

            rowHeight = virtualRowHeight
            i += 1
        }

        // zero-sized children are appended to the row
        while i < count && weights[i] == 0 { i += 1 }
        let used = i - start

        let rowSize = mySize * rowHeight
        if rowSize > 0 {
            for k in 0..<used {
                widths.append(Double(weights[start + k]) / rowSize)
            }
        } else {
            // only zero-sized children left
            for _ in 0..<used { widths.append(1.0 / Double(used)) }
        }
        return (rowHeight, used)
    }
}
