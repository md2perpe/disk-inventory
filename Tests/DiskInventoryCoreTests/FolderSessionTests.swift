import XCTest
import TreeMapKit
@testable import DiskInventoryCore

private func file(_ name: String, _ size: UInt64, _ kind: String = "Document", physical: UInt64? = nil) -> FSItem {
    FSItem(name: name, isDirectory: false, kindName: kind, logicalSize: size, physicalSize: physical ?? size)
}

private func dir(_ name: String, _ children: [FSItem], package: Bool = false) -> FSItem {
    let f = FSItem(name: name, isDirectory: true, isPackage: package, kindName: package ? "Application" : "Folder")
    children.forEach { f.addChild($0) }
    f.finalizeChildren()
    return f
}

/// /r
/// ├── app.app (package: bin 600, res 100)
/// ├── docs    (a.pdf 300, b.txt 50)
/// └── c.txt   20
@MainActor
private func sessionWithPackage() -> (FolderSession, root: FSItem, app: FSItem, docs: FSItem) {
    let app = dir("app.app", [file("bin", 600, "Unix executable"), file("res", 100, "Image")], package: true)
    let docs = dir("docs", [file("a.pdf", 300, "PDF document"), file("b.txt", 50, "Plain text")])
    let root = FSItem(rootURL: URL(fileURLWithPath: "/nonexistent/r"))
    [app, docs, file("c.txt", 20, "Plain text")].forEach { root.addChild($0) }
    root.finalizeChildren()
    let session = FolderSession(url: root.url)
    session.adopt(root: root)
    return (session, root, app, docs)
}

@MainActor
final class FolderSessionTests: XCTestCase {

    // MARK: models built by hand

    func testStatisticsFollowPackageOption() async {
        let (s, _, app, _) = sessionWithPackage()
        XCTAssertFalse(s.showPackageContents)
        XCTAssertEqual(s.kindStatistics.map(\.kindName), ["Application", "PDF document", "Plain text"])
        XCTAssertFalse(s.isNode(app))

        let before = s.revision
        s.setShowPackageContents(true)
        XCTAssertGreaterThan(s.revision, before)
        XCTAssertTrue(s.isNode(app))
        XCTAssertEqual(s.kindStatistics.map(\.kindName), ["Unix executable", "PDF document", "Image", "Plain text"])
    }

    func testHidingPackageContentsMovesSelectionToPackage() async {
        let (s, _, app, _) = sessionWithPackage()
        s.setShowPackageContents(true)
        s.select(app.children[0])
        s.setShowPackageContents(false)
        XCTAssertTrue(s.selectedItem === app)
    }

    func testZoomInAndOut() async {
        let (s, root, _, docs) = sessionWithPackage()
        XCTAssertTrue(s.zoomedItem === root)
        XCTAssertFalse(s.canZoomIn)

        s.select(docs)
        XCTAssertTrue(s.canZoomIn)
        s.zoomIn()
        XCTAssertTrue(s.zoomedItem === docs)
        XCTAssertNil(s.selectedItem, "zooming in clears the selection")
        XCTAssertEqual(s.kindStatistics.map(\.kindName), ["PDF document", "Plain text"], "statistics only cover the zoomed folder")
        XCTAssertTrue(s.isNode(docs), "the zoomed item is always a node")
        XCTAssertTrue(s.canZoomOut)

        s.zoomOut()
        XCTAssertTrue(s.zoomedItem === root)
        XCTAssertTrue(s.selectedItem === docs, "zooming out selects the folder we left")
        XCTAssertFalse(s.canZoomOut)
    }

    func testCanZoomIntoPackageEvenIfHidden() async {
        let (s, _, app, _) = sessionWithPackage()
        s.select(app)
        XCTAssertTrue(s.canZoomIn)
        s.zoomIn()
        XCTAssertEqual(s.kindStatistics.map(\.kindName), ["Unix executable", "Image"])
    }

    func testZoomOutToItem() async {
        let inner = dir("inner", [file("x", 1)])
        let mid = dir("mid", [inner])
        let root = FSItem(rootURL: URL(fileURLWithPath: "/nonexistent/z"))
        root.addChild(mid); root.finalizeChildren()
        let s = FolderSession(url: root.url); s.adopt(root: root)
        s.select(mid); s.zoomIn(); s.select(inner); s.zoomIn()
        XCTAssertTrue(s.zoomedItem === inner)
        s.zoomOut(to: mid)
        XCTAssertTrue(s.zoomedItem === mid)
        XCTAssertTrue(s.selectedItem === inner)
        s.zoomOut(to: root)
        XCTAssertTrue(s.zoomedItem === root)
        XCTAssertTrue(s.zoomStack.isEmpty)
    }

    func testSelectParent() async {
        let (s, root, app, docs) = sessionWithPackage()
        s.setShowPackageContents(true)
        let bin = app.children[0]
        s.select(bin)
        XCTAssertTrue(s.canSelectParent)
        s.selectParent()
        XCTAssertTrue(s.selectedItem === app)
        XCTAssertFalse(s.canSelectParent, "children of the zoomed item have no selectable parent")
        s.select(root)
        XCTAssertFalse(s.canSelectParent)
        s.select(docs.children[0]); s.selectParent()
        XCTAssertTrue(s.selectedItem === docs)
    }

    func testSpecialItemsCannotBeSelected() async {
        let (s, _, _, docs) = sessionWithPackage()
        s.select(docs)
        s.select(FSItem(specialType: .freeSpace, size: 1, parent: nil))
        XCTAssertNil(s.selectedItem)
    }

    func testSizeModeSwitchChangesTotalsAndOrder() async {
        let a = file("a", 100, physical: 10), b = file("b", 50, physical: 500)
        let root = FSItem(rootURL: URL(fileURLWithPath: "/nonexistent/m"))
        root.addChild(a); root.addChild(b); root.finalizeChildren()
        let s = FolderSession(url: root.url); s.adopt(root: root)
        XCTAssertEqual(root.children.map(\.name), ["a", "b"])
        s.setPhysicalSizes(true)
        XCTAssertEqual(root.children.map(\.name), ["b", "a"])
        XCTAssertEqual(root.size, 510)
        XCTAssertEqual(s.kindStatistics.first?.size, 510)
        s.setPhysicalSizes(false)
        XCTAssertEqual(root.size, 150)
    }

    func testTreeMapSourceIncludesSpaceItemsOnDemand() async {
        let (s, root, _, _) = sessionWithPackage()
        XCTAssertEqual(s.treeMapSource()?.extras.count, 0)
        s.setShowFreeSpace(true)
        XCTAssertEqual(s.treeMapSource()?.extras.map(\.type), [.freeSpace])
        s.setShowOtherSpace(true)
        XCTAssertEqual(s.treeMapSource()?.extras.map(\.type), [.otherSpace, .freeSpace])

        let source = s.treeMapSource()!
        XCTAssertEqual(source.weight(of: root), root.size + source.extras.reduce(0) { $0 + $1.size })
        XCTAssertEqual(source.children(of: root)?.count, root.children.count + 2)
        XCTAssertNil(source.children(of: source.extras[0]), "pseudo items are leaves")
    }

    func testTreeMapSourceTreatsHiddenPackagesAsLeaves() async {
        let (s, _, app, docs) = sessionWithPackage()
        XCTAssertNil(s.treeMapSource()?.children(of: app))
        XCTAssertNotNil(s.treeMapSource()?.children(of: docs))
        s.setShowPackageContents(true)
        XCTAssertNotNil(s.treeMapSource()?.children(of: app))
    }

    func testEndToEndLayoutAndRenderingOfSession() async {
        let (s, _, _, _) = sessionWithPackage()
        s.setShowPackageContents(true)
        let source = s.treeMapSource()!
        let cell = TreeMapLayout.layout(root: source.top, in: PixelRect(x: 0, y: 0, width: 200, height: 120), source: source)
        let img = CushionRenderer.render(root: cell, width: 200, height: 120, background: RGB(r: 0, g: 0, b: 0)) { s.color(for: $0) }
        let black = stride(from: 0, to: img.bytes.count, by: 4).filter { img.bytes[$0] == 0 && img.bytes[$0 + 1] == 0 && img.bytes[$0 + 2] == 0 }
        XCTAssertEqual(black.count, 0)
    }

    func testColorsOfPseudoItems() async {
        let (s, root, _, _) = sessionWithPackage()
        XCTAssertEqual(s.color(for: FSItem(specialType: .freeSpace, size: 1, parent: root)), FileTypeColors.freeSpaceColor)
        XCTAssertEqual(s.color(for: FSItem(specialType: .otherSpace, size: 1, parent: root)), FileTypeColors.otherSpaceColor)
    }

    func testItemsOfKind() async {
        let (s, _, _, _) = sessionWithPackage()
        XCTAssertEqual(s.items(ofKind: "Plain text").map(\.name).sorted(), ["b.txt", "c.txt"])
        XCTAssertEqual(s.items(ofKind: nil).count, 4)
        XCTAssertTrue(s.items(ofKind: "nope").isEmpty)
    }

    func testSwitchingColorSharingResetsAndReassigns() async {
        let (s, _, _, _) = sessionWithPackage()
        let before = s.color(for: s.rootItem!.children[0])
        s.setSharesColors(true)
        XCTAssertTrue(s.sharesColors)
        let after = s.color(for: s.rootItem!.children[0])
        XCTAssertEqual(before, after, "biggest kind gets the first colour in both palettes")
        s.setSharesColors(false)
        FileTypeColors.shared.reset()
    }

    // MARK: real file system

    private var temp: URL!

    override func setUp() async throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("dix-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = temp.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    func testScanPublishesResult() async throws {
        try write("a.txt", bytes: 100)
        try write("sub/b.txt", bytes: 900)
        let s = FolderSession(url: temp)
        XCTAssertNil(s.rootItem)
        await s.scan()
        XCTAssertNil(s.failure)
        XCTAssertNil(s.scanProgress)
        XCTAssertEqual(s.rootItem?.size, 1000)
        XCTAssertGreaterThan(s.revision, 0)
        XCTAssertEqual(s.kindStatistics.reduce(0) { $0 + $1.size }, 1000)
        XCTAssertTrue(s.title.contains(temp.lastPathComponent))
    }

    func testScanOfMissingFolderFails() async {
        let s = FolderSession(url: temp.appendingPathComponent("missing"))
        await s.scan()
        XCTAssertNotNil(s.failure)
        XCTAssertNil(s.rootItem)
        XCTAssertNil(s.scanProgress)
    }

    func testScanRunsOnlyOnce() async throws {
        try write("a", bytes: 1)
        let s = FolderSession(url: temp)
        await s.scan()
        let rev = s.revision
        await s.scan()
        XCTAssertEqual(s.revision, rev)
    }

    func testSpaceItemsReflectVolume() async throws {
        try write("a", bytes: 10)
        let s = FolderSession(url: temp)
        await s.scan()
        XCTAssertNotNil(s.freeSpaceItem)
        XCTAssertNotNil(s.otherSpaceItem)
        XCTAssertGreaterThan(s.freeSpaceItem!.size, 0)
    }

    func testRefreshPicksUpChangesAndKeepsZoomAndSelection() async throws {
        try write("keep/big.bin", bytes: 5000)
        try write("keep/small.txt", bytes: 10)
        try write("other.txt", bytes: 20)
        let s = FolderSession(url: temp)
        await s.scan()

        let keep = try XCTUnwrap(s.rootItem?.children.first { $0.name == "keep" })
        s.select(keep); s.zoomIn()
        s.select(keep.children.first { $0.name == "small.txt" })

        try write("keep/new.dat", bytes: 700)
        await s.refresh(nil)   // refreshes the zoomed folder

        XCTAssertEqual(s.zoomedItem?.name, "keep")
        XCTAssertEqual(s.zoomedItem?.size, 5710)
        XCTAssertEqual(s.rootItem?.size, 5730, "ancestors are updated")
        XCTAssertEqual(s.selectedItem?.name, "small.txt")
        XCTAssertTrue(s.selectedItem !== keep.children.first { $0.name == "small.txt" }, "items are new objects")
        XCTAssertEqual(s.zoomedItem?.children.map(\.name), ["big.bin", "new.dat", "small.txt"])
    }

    func testRefreshOfVanishedZoomedFolderZoomsOut() async throws {
        try write("a/b/file", bytes: 100)
        try write("x", bytes: 1)
        let s = FolderSession(url: temp)
        await s.scan()
        let a = try XCTUnwrap(s.rootItem?.children.first { $0.name == "a" })
        s.select(a); s.zoomIn()
        let b = try XCTUnwrap(a.children.first)
        s.select(b); s.zoomIn()
        XCTAssertEqual(s.zoomStack.count, 2)

        try FileManager.default.removeItem(at: temp.appendingPathComponent("a/b"))
        await s.refresh(nil)

        XCTAssertEqual(s.zoomedItem?.name, "a", "zoomed folder is gone, so we end up in its closest existing ancestor")
        XCTAssertEqual(s.rootItem?.size, 1)
    }

    func testRefreshAll() async throws {
        try write("a", bytes: 10)
        let s = FolderSession(url: temp)
        await s.scan()
        try write("b", bytes: 90)
        await s.refresh(s.rootItem)
        XCTAssertEqual(s.rootItem?.size, 100)
    }

    func testMoveToTrashRemovesFileAndUpdatesModel() async throws {
        try write("sub/victim.bin", bytes: 400)
        try write("sub/stay.txt", bytes: 100)
        let s = FolderSession(url: temp)
        var trashed: [(URL, Bool)] = []
        s.trashHandler = { url, permanent in trashed.append((url, permanent)); try FileManager.default.removeItem(at: url) }
        await s.scan()

        let sub = try XCTUnwrap(s.rootItem?.children.first)
        let victim = try XCTUnwrap(sub.children.first { $0.name == "victim.bin" })
        s.select(victim)
        let rev = s.revision

        XCTAssertTrue(s.canTrash(victim))
        s.requestTrash(victim)

        XCTAssertEqual(trashed.count, 1)
        XCTAssertEqual(trashed[0].0.lastPathComponent, "victim.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("sub/victim.bin").path))
        XCTAssertEqual(s.rootItem?.size, 100)
        XCTAssertEqual(sub.children.map(\.name), ["stay.txt"])
        XCTAssertTrue(s.selectedItem === sub, "selection moves to the parent")
        XCTAssertGreaterThan(s.revision, rev)
        XCTAssertEqual(s.kindStatistics.reduce(0) { $0 + $1.size }, 100)
    }

    func testTrashFailureKeepsModelAndReportsError() async throws {
        try write("f", bytes: 5)
        let s = FolderSession(url: temp)
        struct Boom: Error {}
        s.trashHandler = { _, _ in throw Boom() }
        await s.scan()
        let f = try XCTUnwrap(s.rootItem?.children.first)
        XCTAssertFalse(s.moveToTrash(f, permanently: false))
        XCTAssertNotNil(s.errorMessage)
        XCTAssertEqual(s.rootItem?.children.count, 1)
    }

    func testZoomedItemAndRootCannotBeTrashed() async throws {
        try write("d/f", bytes: 5)
        let s = FolderSession(url: temp)
        await s.scan()
        XCTAssertFalse(s.canTrash(s.rootItem))
        let d = try XCTUnwrap(s.rootItem?.children.first)
        s.select(d); s.zoomIn()
        XCTAssertFalse(s.canTrash(d), "can't trash the folder you are looking into")
        XCTAssertTrue(s.canTrash(d.children.first))
        XCTAssertFalse(s.canTrash(nil))
    }
}
