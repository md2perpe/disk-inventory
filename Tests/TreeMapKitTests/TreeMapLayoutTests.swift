import XCTest
@testable import TreeMapKit

/// Simple test tree.
final class Node {
    let weightOverride: UInt64?
    let kids: [Node]?
    let leafWeight: UInt64
    let name: String

    init(_ name: String = "", weight: UInt64) {
        self.name = name; self.leafWeight = weight; self.kids = nil; self.weightOverride = nil
    }
    init(_ name: String = "", children: [Node], weightOverride: UInt64? = nil) {
        self.name = name; self.leafWeight = 0; self.kids = children; self.weightOverride = weightOverride
    }
    var weight: UInt64 { weightOverride ?? kids.map { $0.reduce(0) { $0 + $1.weight } } ?? leafWeight }
}

struct NodeSource: TreeMapDataSource {
    func children(of item: Node) -> [Node]? { item.kids }
    func weight(of item: Node) -> UInt64 { item.weight }
}

/// Deterministic random numbers so failures are reproducible.
struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

func randomTree(depth: Int, rng: inout LCG) -> Node {
    if depth == 0 || Int.random(in: 0..<5, using: &rng) == 0 {
        // leaves: a mix of zero, tiny and huge sizes
        let w: UInt64 = [0, 1, 10, 1000, 100_000, 10_000_000].randomElement(using: &rng)!
        return Node(weight: w)
    }
    let n = Int.random(in: 1...12, using: &rng)
    let kids = (0..<n).map { _ in randomTree(depth: depth - 1, rng: &rng) }
    return Node(children: kids.sorted { $0.weight > $1.weight })
}

final class TreeMapLayoutTests: XCTestCase {

    /// Every non-empty node's children must lie inside it and exactly tile it (no gaps, no overlaps).
    private func assertTiles(_ cell: TreeMapCell<Node>, file: StaticString = #filePath, line: UInt = #line) {
        guard !cell.isLeaf, !cell.children.isEmpty else { return }
        let r = cell.rect
        var coverage = [Int](repeating: 0, count: max(1, r.width * r.height))
        for child in cell.children {
            let c = child.rect
            XCTAssertGreaterThanOrEqual(c.x, r.x, file: file, line: line)
            XCTAssertGreaterThanOrEqual(c.y, r.y, file: file, line: line)
            XCTAssertLessThanOrEqual(c.maxX, r.maxX, file: file, line: line)
            XCTAssertLessThanOrEqual(c.maxY, r.maxY, file: file, line: line)
            for y in max(c.y, r.y)..<min(c.maxY, r.maxY) {
                for x in max(c.x, r.x)..<min(c.maxX, r.maxX) {
                    coverage[(y - r.y) * r.width + (x - r.x)] += 1
                }
            }
        }
        XCTAssertTrue(coverage.allSatisfy { $0 == 1 }, "children of a node must tile it exactly", file: file, line: line)
        cell.children.forEach { assertTiles($0, file: file, line: line) }
    }

    func testChildrenTileParentExactly() {
        var rng = LCG(state: 42)
        for _ in 0..<40 {
            let tree = randomTree(depth: 4, rng: &rng)
            let w = Int.random(in: 40...300, using: &rng)
            let h = Int.random(in: 40...300, using: &rng)
            let cell = TreeMapLayout.layout(root: tree, in: PixelRect(x: 0, y: 0, width: w, height: h), source: NodeSource())
            XCTAssertEqual(cell.rect, PixelRect(x: 0, y: 0, width: w, height: h))
            assertTiles(cell)
        }
    }

    func testLayoutWithNonZeroOrigin() {
        let tree = Node(children: [Node(weight: 60), Node(weight: 30), Node(weight: 10)])
        let cell = TreeMapLayout.layout(root: tree, in: PixelRect(x: 17, y: 5, width: 100, height: 50), source: NodeSource())
        assertTiles(cell)
        XCTAssertEqual(cell.children.reduce(0) { $0 + $1.rect.width * $1.rect.height }, 100 * 50)
    }

    func testAreasAreProportionalToWeights() {
        let tree = Node(children: [Node(weight: 500), Node(weight: 300), Node(weight: 150), Node(weight: 50)])
        let cell = TreeMapLayout.layout(root: tree, in: PixelRect(x: 0, y: 0, width: 1000, height: 600), source: NodeSource())
        let total = 1000.0 * 600.0
        for (child, expected) in zip(cell.children, [0.5, 0.3, 0.15, 0.05]) {
            let area = Double(child.rect.width * child.rect.height)
            XCTAssertEqual(area / total, expected, accuracy: 0.01)
        }
    }

    func testBiggestChildGetsBiggestArea() {
        var rng = LCG(state: 7)
        let kids = (0..<30).map { _ in Node(weight: UInt64.random(in: 1...10_000, using: &rng)) }.sorted { $0.weight > $1.weight }
        let cell = TreeMapLayout.layout(root: Node(children: kids), in: PixelRect(x: 0, y: 0, width: 800, height: 600), source: NodeSource())
        let areas = cell.children.map { $0.rect.width * $0.rect.height }
        XCTAssertEqual(areas.first, areas.max())
    }

    func testZeroWeightNodeDividesEqually() {
        let tree = Node(children: [Node(children: []), Node(children: []), Node(children: []), Node(children: [])])
        let cell = TreeMapLayout.layout(root: tree, in: PixelRect(x: 0, y: 0, width: 400, height: 100), source: NodeSource())
        XCTAssertEqual(cell.children.count, 4)
        XCTAssertTrue(cell.children.allSatisfy { $0.rect.width == 100 && $0.rect.height == 100 })
    }

    func testZeroSizedChildrenDontBreakLayout() {
        let tree = Node(children: [Node(weight: 100), Node(weight: 0), Node(weight: 0)])
        let cell = TreeMapLayout.layout(root: tree, in: PixelRect(x: 0, y: 0, width: 100, height: 100), source: NodeSource())
        assertTiles(cell)
    }

    func testUnsortedChildrenStillTile() {
        let tree = Node(children: [Node(weight: 1), Node(weight: 100), Node(weight: 5), Node(weight: 700), Node(weight: 0), Node(weight: 40)])
        let cell = TreeMapLayout.layout(root: tree, in: PixelRect(x: 0, y: 0, width: 333, height: 211), source: NodeSource())
        assertTiles(cell)
    }

    func testInconsistentParentWeightDoesNotCrashOrOverflow() {
        // parent claims to be smaller than the sum of its children
        let tree = Node(children: [Node(weight: 100), Node(weight: 100)], weightOverride: 50)
        let cell = TreeMapLayout.layout(root: tree, in: PixelRect(x: 0, y: 0, width: 100, height: 100), source: NodeSource())
        for c in cell.children {
            XCTAssertLessThanOrEqual(c.rect.maxX, 100)
            XCTAssertLessThanOrEqual(c.rect.maxY, 100)
        }
    }

    func testTinyNodesAreNotSubdivided() {
        let inner = Node(children: [Node(weight: 1), Node(weight: 1)])
        let tree = Node(children: [Node(weight: 1_000_000), inner])
        let cell = TreeMapLayout.layout(root: tree, in: PixelRect(x: 0, y: 0, width: 50, height: 50), source: NodeSource())
        // the inner node has (almost) no area; whatever its size it must not have laid-out children smaller than 1px
        func check(_ c: TreeMapCell<Node>) {
            for k in c.children { XCTAssertFalse(k.rect.isEmpty); check(k) }
        }
        check(cell)
    }

    func testHitTestFindsLeafUnderPixel() {
        var rng = LCG(state: 99)
        let tree = randomTree(depth: 3, rng: &rng)
        let cell = TreeMapLayout.layout(root: tree, in: PixelRect(x: 0, y: 0, width: 200, height: 150), source: NodeSource())
        for _ in 0..<500 {
            let x = Int.random(in: 0..<200, using: &rng), y = Int.random(in: 0..<150, using: &rng)
            if let hit = cell.hitTest(x: x, y: y) {
                XCTAssertTrue(hit.rect.contains(x: x, y: y))
                XCTAssertTrue(hit.isLeaf || hit.children.isEmpty)
            }
        }
        XCTAssertNil(cell.hitTest(x: -1, y: 0))
        XCTAssertNil(cell.hitTest(x: 200, y: 0))
    }

    func testCellForPath() {
        let a = Node("a", weight: 10), b = Node("b", weight: 5)
        let folder = Node("folder", children: [a, b])
        let root = Node("root", children: [folder, Node("c", weight: 1)])
        let cell = TreeMapLayout.layout(root: root, in: PixelRect(x: 0, y: 0, width: 100, height: 100), source: NodeSource())
        XCTAssertTrue(cell.cell(forPath: [root, folder, b])?.item === b)
        XCTAssertTrue(cell.cell(forPath: [root])?.item === root)
        XCTAssertNil(cell.cell(forPath: [folder]))                 // must start at the root
        XCTAssertNil(cell.cell(forPath: [root, b]))                // b is not a direct child
    }

    func testLeafRootHasNoChildren() {
        let cell = TreeMapLayout.layout(root: Node(weight: 5), in: PixelRect(x: 0, y: 0, width: 10, height: 10), source: NodeSource())
        XCTAssertTrue(cell.isLeaf)
        XCTAssertTrue(cell.children.isEmpty)
        XCTAssertTrue(cell.hitTest(x: 3, y: 3) === cell)
    }

    func testLayoutOfManyItemsIsFast() {
        let kids = (0..<50_000).map { Node(weight: UInt64(50_000 - $0)) }
        let tree = Node(children: kids)
        measure {
            _ = TreeMapLayout.layout(root: tree, in: PixelRect(x: 0, y: 0, width: 1600, height: 1000), source: NodeSource())
        }
    }
}
