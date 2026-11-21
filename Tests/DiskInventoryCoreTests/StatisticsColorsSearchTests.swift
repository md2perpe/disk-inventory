import XCTest
import TreeMapKit
@testable import DiskInventoryCore

private func file(_ name: String, _ size: UInt64, _ kind: String) -> FSItem {
    FSItem(name: name, isDirectory: false, kindName: kind, logicalSize: size, physicalSize: size)
}

final class StatisticsColorsSearchTests: XCTestCase {

    private func tree() -> (root: FSItem, pkg: FSItem) {
        let pkg = FSItem(name: "Tool.app", isDirectory: true, isPackage: true, kindName: "Application")
        pkg.addChild(file("exe", 800, "Unix executable")); pkg.addChild(file("icon.icns", 50, "Apple icon image")); pkg.finalizeChildren()
        let sub = FSItem(name: "sub", isDirectory: true, kindName: "Folder")
        sub.addChild(file("c.pdf", 400, "PDF document")); sub.addChild(file("d.txt", 5, "Plain text")); sub.finalizeChildren()
        let root = FSItem(rootURL: URL(fileURLWithPath: "/r"))
        [file("a.pdf", 300, "PDF document"), file("b.txt", 20, "Plain text"), sub, pkg].forEach(root.addChild)
        root.finalizeChildren()
        return (root, pkg)
    }

    func testStatisticsTreatPackagesAsFilesWhenHidden() {
        let (root, _) = tree()
        let stats = FileKindStatistics.collect(from: root) { $0.isFolder && !$0.isPackage }
        XCTAssertEqual(stats.map(\.kindName), ["Application", "PDF document", "Plain text"])
        XCTAssertEqual(stats[0].size, 850)
        XCTAssertEqual(stats[0].fileCount, 1)
        XCTAssertEqual(stats[1].size, 700)
        XCTAssertEqual(stats[1].fileCount, 2)
        XCTAssertEqual(stats.reduce(0) { $0 + $1.size }, root.size)
    }

    func testStatisticsTiesAreOrderedByKindName() {
        let root = FSItem(rootURL: URL(fileURLWithPath: "/r"))
        root.addChild(file("1", 10, "Zebra")); root.addChild(file("2", 10, "Apple")); root.finalizeChildren()
        XCTAssertEqual(FileKindStatistics.collect(from: root) { $0.isFolder }.map(\.kindName), ["Apple", "Zebra"])
    }

    func testStatisticsLookIntoPackages() {
        let (root, _) = tree()
        let stats = FileKindStatistics.collect(from: root) { $0.isFolder }
        XCTAssertEqual(stats.map(\.kindName), ["Unix executable", "PDF document", "Apple icon image", "Plain text"])
        XCTAssertEqual(stats.reduce(0) { $0 + $1.size }, root.size)
    }

    func testStatisticsOfZoomedFolderOnly() {
        let (root, _) = tree()
        let sub = root.children.first { $0.name == "sub" }!
        let stats = FileKindStatistics.collect(from: sub) { $0.isFolder }
        XCTAssertEqual(stats.map(\.kindName), ["PDF document", "Plain text"])
        XCTAssertEqual(stats[0].size, 400)
    }

    func testColorsArePredefinedForFirstTwelveKindsThenGray() {
        let colors = FileTypeColors()
        var seen: [RGB] = []
        for i in 0..<20 { seen.append(colors.color(forKind: "kind\(i)")) }
        XCTAssertEqual(Set(seen.prefix(12)).count, 12, "first twelve colours are distinct")
        XCTAssertEqual(colors.color(forKind: "kind3"), seen[3], "colour of a kind is stable")
        for c in seen.suffix(8) { XCTAssertEqual(c.r, c.g, accuracy: 1e-12); XCTAssertEqual(c.g, c.b, accuracy: 1e-12) }
        for c in seen { XCTAssertEqual(c.r + c.g + c.b, RGB.baseBrightness, accuracy: 1e-9) }
    }

    func testBiggestKindsGetPredefinedColoursFirst() {
        let (root, _) = tree()
        let stats = FileKindStatistics.collect(from: root) { $0.isFolder }
        let colors = FileTypeColors()
        colors.reserveColors(for: stats)
        // blue is the first predefined colour; it belongs to the biggest kind
        XCTAssertEqual(colors.color(forKind: stats[0].kindName), RGB(r: 0, g: 0, b: 1).normalized)
    }

    func testResetForgetsAssignments() {
        let colors = FileTypeColors()
        let first = colors.color(forKind: "x")
        _ = colors.color(forKind: "y")
        colors.reset()
        XCTAssertEqual(colors.color(forKind: "y"), first)
    }

    func testSearchByFieldAndMultipleWords() {
        let (root, _) = tree()
        let all = FileKindStatistics.collect(from: root) { $0.isFolder }.flatMap(\.items)
        XCTAssertEqual(FSItemSearch.filter(all, text: "pdf", field: .name).map(\.name).sorted(), ["a.pdf", "c.pdf"])
        XCTAssertEqual(FSItemSearch.filter(all, text: "PDF doc", field: .kind).count, 2)
        XCTAssertEqual(FSItemSearch.filter(all, text: "sub c", field: .path).map(\.name), ["c.pdf"])
        XCTAssertEqual(FSItemSearch.filter(all, text: "plain a.pdf", field: .all).count, 0)
        XCTAssertEqual(FSItemSearch.filter(all, text: "   ", field: .name).count, all.count)
        XCTAssertEqual(FSItemSearch.filter(all, text: "ICON", field: .name).map(\.name), ["icon.icns"])
    }

    func testSizeFormatting() {
        XCTAssertEqual(SizeFormatting.string(forBytes: 0), "0 bytes")
        XCTAssertTrue(SizeFormatting.string(forBytes: 1_500_000).contains("1.5"))
        XCTAssertTrue(SizeFormatting.string(forBytes: 2_000_000_000).contains("GB"))
        XCTAssertEqual(SizeFormatting.percentString(0.5), "50.0 %")
        XCTAssertEqual(SizeFormatting.percentString(0.00001), "<0.1 %")
        XCTAssertEqual(SizeFormatting.percentString(.nan), "–")
    }
}
