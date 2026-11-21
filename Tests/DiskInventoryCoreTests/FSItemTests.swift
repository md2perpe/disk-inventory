import XCTest
@testable import DiskInventoryCore

private func file(_ name: String, _ size: UInt64, kind: String = "Document") -> FSItem {
    FSItem(name: name, isDirectory: false, kindName: kind, logicalSize: size, physicalSize: size + 4096)
}

private func folder(_ name: String, _ children: [FSItem], package: Bool = false) -> FSItem {
    let f = FSItem(name: name, isDirectory: true, isPackage: package, kindName: package ? "Application" : "Folder")
    children.forEach { f.addChild($0) }
    f.finalizeChildren()
    return f
}

/// root
/// ├── docs        (300)  = a.txt 200 + b.txt 100
/// ├── big.bin     (1000)
/// └── small.txt   (10)
private func makeTree() -> (root: FSItem, docs: FSItem, a: FSItem, b: FSItem, big: FSItem, small: FSItem) {
    let a = file("a.txt", 200), b = file("b.txt", 100)
    let docs = folder("docs", [b, a])
    let big = file("big.bin", 1000), small = file("small.txt", 10)
    let root = FSItem(rootURL: URL(fileURLWithPath: "/tmp/root"))
    [small, docs, big].forEach { root.addChild($0) }
    root.finalizeChildren()
    return (root, docs, a, b, big, small)
}

final class FSItemTests: XCTestCase {

    func testFinalizeSumsAndSortsDescending() {
        let t = makeTree()
        XCTAssertEqual(t.root.size, 1310)
        XCTAssertEqual(t.root.children.map(\.name), ["big.bin", "docs", "small.txt"])
        XCTAssertEqual(t.docs.children.map(\.name), ["a.txt", "b.txt"])
    }

    func testEqualSizesAreOrderedByNameNumerically() {
        let f = folder("f", [file("file10", 5), file("file2", 5), file("File1", 5)])
        XCTAssertEqual(f.children.map(\.name), ["File1", "file2", "file10"])
    }

    func testURLAndPaths() {
        let t = makeTree()
        XCTAssertEqual(t.a.path, "/tmp/root/docs/a.txt")
        XCTAssertEqual(t.docs.folderPath, "/tmp/root")
        XCTAssertEqual(t.a.folderPath, "/tmp/root/docs")
        XCTAssertEqual(t.root.path, "/tmp/root")
        XCTAssertTrue(t.docs.url.hasDirectoryPath)
        XCTAssertEqual(t.a.pathFromRoot.map(\.name), ["root", "docs", "a.txt"])
        XCTAssertEqual(t.a.pathFromAncestor(t.docs).map(\.name), ["docs", "a.txt"])
        XCTAssertTrue(t.a.isDescendant(of: t.root))
        XCTAssertFalse(t.root.isDescendant(of: t.a))
        XCTAssertTrue(t.a.root === t.root)
    }

    func testRemoveChildUpdatesAllAncestors() {
        let t = makeTree()
        XCTAssertTrue(t.docs.removeChild(t.a))
        XCTAssertEqual(t.docs.size, 100)
        XCTAssertEqual(t.root.size, 1110)
        XCTAssertNil(t.a.parent)
        // docs (100) is now smaller than small.txt? no: 100 > 10, order unchanged
        XCTAssertEqual(t.root.children.map(\.name), ["big.bin", "docs", "small.txt"])
        // removing b makes docs empty (0) -> sorts behind small.txt
        XCTAssertTrue(t.docs.removeChild(t.b))
        XCTAssertEqual(t.root.children.map(\.name), ["big.bin", "small.txt", "docs"])
        XCTAssertFalse(t.docs.removeChild(t.a), "removing twice must fail")
    }

    func testInsertChildKeepsOrderAndSizes() {
        let t = makeTree()
        let extra = file("extra", 500)
        t.root.insertChild(extra)
        XCTAssertEqual(t.root.size, 1810)
        XCTAssertEqual(t.root.children.map(\.name), ["big.bin", "extra", "docs", "small.txt"])
        // growing a subfolder re-sorts the parent
        t.docs.insertChild(file("huge", 5000))
        XCTAssertEqual(t.root.children.first?.name, "docs")
        XCTAssertEqual(t.root.size, 6810)
    }

    func testReplaceChild() {
        let t = makeTree()
        let replacement = folder("docs", [file("only.txt", 7)])
        t.root.replaceChild(t.docs, with: replacement)
        XCTAssertEqual(t.root.size, 1017)
        XCTAssertTrue(replacement.parent === t.root)
        XCTAssertNil(t.docs.parent)
    }

    func testSizeModeSwitchResorts() {
        // logical: x=100, y=90 ; physical adds 4096 to each so the order stays; craft different order explicitly
        let x = FSItem(name: "x", isDirectory: false, kindName: "k", logicalSize: 100, physicalSize: 10)
        let y = FSItem(name: "y", isDirectory: false, kindName: "k", logicalSize: 90, physicalSize: 50)
        let f = folder("f", [x, y])
        XCTAssertEqual(f.children.map(\.name), ["x", "y"])
        XCTAssertEqual(f.size, 190)
        f.applySizeMode(.physical)
        XCTAssertEqual(f.children.map(\.name), ["y", "x"])
        XCTAssertEqual(f.size, 60)
        XCTAssertEqual(x.size, 10)
        f.applySizeMode(.logical)
        XCTAssertEqual(f.children.map(\.name), ["x", "y"])
    }

    func testFindItemByPath() {
        let t = makeTree()
        XCTAssertTrue(t.root.findItem(atPath: "/tmp/root/docs/b.txt", allowAncestors: false) === t.b)
        XCTAssertTrue(t.root.findItem(atPath: "/tmp/root", allowAncestors: false) === t.root)
        XCTAssertNil(t.root.findItem(atPath: "/tmp/root/docs/missing", allowAncestors: false))
        XCTAssertTrue(t.root.findItem(atPath: "/tmp/root/docs/missing/deeper", allowAncestors: true) === t.docs)
        XCTAssertNil(t.root.findItem(atPath: "/tmp/rootX/docs", allowAncestors: true), "prefix match must respect path components")
        XCTAssertNil(t.root.findItem(atPath: "/elsewhere", allowAncestors: true))
    }

    func testSymbolicLinkToDirectoryIsNotAFolder() {
        let link = FSItem(name: "link", isDirectory: true, isSymbolicLink: true, kindName: "Alias")
        XCTAssertFalse(link.isFolder)
        XCTAssertNil(link.outlineChildren)
    }

    func testDeepFileCount() {
        let pkg = folder("App.app", [file("bin", 1), file("res", 1)], package: true)
        let root = FSItem(rootURL: URL(fileURLWithPath: "/r"))
        root.addChild(pkg); root.addChild(file("x", 1)); root.addChild(folder("d", [file("y", 1)]))
        root.finalizeChildren()
        XCTAssertEqual(root.deepFileCount(includingPackages: true), 4)
        XCTAssertEqual(root.deepFileCount(includingPackages: false), 2)
    }

    func testSpecialItems() {
        let t = makeTree()
        let free = FSItem(specialType: .freeSpace, size: 42, parent: t.root)
        XCTAssertTrue(free.isSpecialItem)
        XCTAssertEqual(free.size, 42)
        XCTAssertEqual(free.url, t.root.url, "special items resolve to the root's URL")
        XCTAssertFalse(free.isFolder)
    }

    func testPathRelativeToRoot() {
        let t = makeTree()
        XCTAssertTrue(t.a.pathRelativeToRoot.hasSuffix("/docs/a.txt"))
    }
}
